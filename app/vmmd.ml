(* (c) 2017 Hannes Mehnert, all rights reserved *)

type stats = {
  start : Ptime.t ;
  vm_created : int ;
  vm_destroyed : int ;
}

let s = ref { start = Ptime_clock.now () ; vm_created = 0 ; vm_destroyed = 0 }

let pp_stats ppf s =
  let diff = Ptime.(diff (Ptime_clock.now ()) s.start) in
  Fmt.pf ppf "up %a: %d vms created, %d vms destroyed, %d running"
    Ptime.Span.pp diff
    s.vm_created s.vm_destroyed (s.vm_created - s.vm_destroyed)

open Lwt.Infix

type out = [
  | `Cons of Cstruct.t
  | `Stat of Cstruct.t
  | `Log of Cstruct.t
]

let handle state out c_fd fd addr =
  (* out is for `Log | `Stat | `Cons (including reconnect semantics) *)
  (* need to handle data out (+ die on write failure) *)
  Logs.debug (fun m -> m "connection from %a" Vmm_lwt.pp_sockaddr addr) ;
  (* now we need to read a packet and handle it
    (1)
     (a) easy for info (look up name/prefix in resources)
     (b) destroy looks up vm in resources, executes kill (wait for pid will do the cleanup)
         logs "destroy issued"
     (c) create initiates the vm startup procedure:
         write image file, create fifo, create tap(s), send fifo to console
         -- Lwt effects happen (console) --
         executes ukvm-bin + waiter, send stats pid and taps, inserts await into state, logs "created vm"
         -- Lwt effects happen (stats, logs, wait_and_clear) --
    (2) goto (1)
  *)
  let process xs =
    Lwt_list.iter_p (function
        | #out as o -> out o
        | `Data cs ->
          (* rather: terminate connection *)
          Vmm_lwt.write_wire fd cs >|= fun _ -> ()) xs
  in
  Logs.debug (fun m -> m "now reading") ;
  (Vmm_lwt.read_wire fd >>= function
    | Error _ ->
      Logs.err (fun m -> m "error while reading") ;
      Lwt.return_unit
    | Ok (hdr, buf) ->
      Logs.debug (fun m -> m "read sth") ;
      let state', data, next = Vmm_engine.handle_command !state hdr buf in
      state := state' ;
      process data >>= fun () ->
      match next with
      | `End -> Lwt.return_unit
      | `Wait (task, out) -> task >>= fun () -> process out
      | `Create cont ->
        (* data contained a write to console, we need to wait for its reply first *)
        Vmm_lwt.read_wire c_fd >>= function
        | Ok (_, data) when Vmm_wire.is_fail hdr ->
          Logs.err (fun m -> m "console failed with %s" (Cstruct.to_string data)) ;
          Lwt.return_unit
        | Ok (_, _) when Vmm_wire.is_reply hdr ->
          (* assert hdr.id = id! *)
          (* TODO slightly more tricky, since we need to "Vmm_lwt.wait_and_clear" in here *)
          let await, wakeme = Lwt.wait () in
          begin match cont !state await with
            | Error (`Msg msg) ->
              Logs.err (fun m -> m "create continuation failed %s" msg) ;
              Lwt.return_unit
            | Ok (state'', out, vm) ->
              state := state'' ;
              s := { !s with vm_created = succ !s.vm_created } ;
              Lwt.async (fun () ->
                  Vmm_lwt.wait_and_clear vm.Vmm_core.pid vm.Vmm_core.stdout >>= fun r ->
                  let state', out' = Vmm_engine.handle_shutdown !state vm r in
                  s := { !s with vm_destroyed = succ !s.vm_destroyed } ;
                  state := state' ;
                  process out' >|= fun () ->
                  Lwt.wakeup wakeme ()) ;
              process out >>= fun () ->
              begin match Vmm_engine.setup_stats !state vm with
                | Ok (state', out) ->
                  state := state' ;
                  process out (* TODO: need to read from stats socket! *)
                | Error (`Msg e) ->
                  Logs.warn (fun m -> m "(ignored) error %s while setting up statistics" e) ;
                  Lwt.return_unit
              end
          end
        | _ ->
          Logs.err (fun m -> m "error while reading from console") ;
          Lwt.return_unit) >>= fun () ->
  Vmm_lwt.safe_close fd

let init_sock dir name =
  let c = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
  Lwt_unix.set_close_on_exec c ;
  let addr = Fpath.(dir / name + "sock") in
  Lwt.catch (fun () ->
      Lwt_unix.(connect c (ADDR_UNIX (Fpath.to_string addr))) >|= fun () -> Some c)
    (fun e ->
       Logs.warn (fun m -> m "error %s connecting to socket %a"
                     (Printexc.to_string e) Fpath.pp addr) ;
       (Lwt.catch (fun () -> Lwt_unix.close c) (fun _ -> Lwt.return_unit)) >|= fun () ->
       None)

let create_mbox name =
  init_sock Vmm_core.tmpdir name >|= function
  | None -> None
  | Some fd ->
    let mvar = Lwt_mvar.create_empty () in
    (* could be more elaborate:
       if <log> fails, we can reconnect and spit our more log messages to the new socket
       if <console> fails, all running VMs terminate, so we can terminate as well ;)
       if <stat> fails, we'd need to retransmit all VM info to stat (or stat has to ask at connect) *)
    let rec loop () =
      Lwt_mvar.take mvar >>= fun data ->
      Vmm_lwt.write_wire fd data >>= function
      | Ok () -> loop ()
      | Error `Exception -> invalid_arg ("exception while writing to " ^ name) ;
    in
    Lwt.async loop ;
    Some (mvar, fd)

let server_socket dir name =
  let file = Fpath.(dir / name + "sock") in
  let sock = Fpath.to_string file in
  (Lwt_unix.file_exists sock >>= function
    | true -> Lwt_unix.unlink sock
    | false -> Lwt.return_unit) >>= fun () ->
  let s = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
  Lwt_unix.(bind s (ADDR_UNIX sock)) >|= fun () ->
  Lwt_unix.listen s 1 ;
  s

let rec stats_loop () =
  Logs.info (fun m -> m "%a" pp_stats !s) ;
  Lwt_unix.sleep 600. >>= fun () ->
  stats_loop ()

let jump _ =
  Sys.(set_signal sigpipe Signal_ignore) ;
  Lwt_main.run
    (server_socket Vmm_core.tmpdir "vmmd" >>= fun ss ->
     (create_mbox "cons" >|= function
       | None -> invalid_arg "cannot connect to console socket"
       | Some c -> c) >>= fun (c, c_fd) ->
     create_mbox "stat" >>= fun s ->
     (create_mbox "log" >|= function
       | None -> invalid_arg "cannot connect to log socket"
       | Some l -> l) >>= fun (l, _l_fd) ->
     let state = ref (Vmm_engine.init ()) in
     let out = function
       | `Stat data -> (match s with None -> Lwt.return_unit | Some (s, _s_fd) -> Lwt_mvar.put s data)
       | `Log data -> Lwt_mvar.put l data
       | `Cons data -> Lwt_mvar.put c data
     in
     Lwt.async stats_loop ;
     let rec loop () =
       Lwt_unix.accept ss >>= fun (fd, addr) ->
       Lwt_unix.set_close_on_exec fd ;
       Lwt.async (fun () -> handle state out c_fd fd addr) ;
       loop ()
     in
     loop ())

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ~dst:Format.std_formatter ())

open Cmdliner

let setup_log =
  Term.(const setup_log
        $ Fmt_cli.style_renderer ()
        $ Logs_cli.level ())

let cmd =
  Term.(ret (const jump $ setup_log)),
  Term.info "vmmd" ~version:"%%VERSION_NUM%%"

let () = match Term.eval cmd with `Ok () -> exit 0 | _ -> exit 1
