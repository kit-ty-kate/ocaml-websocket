(*
 * Copyright (c) 2012-2015 Vincent Bernardoff <vb@luminar.eu.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Lwt.Infix

module C = Cohttp
module CU = Cohttp_lwt_unix
module CB = Cohttp_lwt_body

let section = Lwt_log.Section.make "websocket"

let random_string ?(base64=false) size =
  Nocrypto.Rng.generate size |>
  (if base64 then Nocrypto.Base64.encode else fun s -> s) |>
  Cstruct.to_string

let b64_encoded_sha1sum s =
  let open Nocrypto in
  Cstruct.of_string s |>
  Hash.SHA1.digest |>
  Base64.encode |>
  Cstruct.to_string

let websocket_uuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

module Frame = struct
  module Opcode = struct
    type t =
      | Continuation
      | Text
      | Binary
      | Close
      | Ping
      | Pong
      | Ctrl of int
      | Nonctrl of int [@@deriving show]

    let min = 0x0
    let max = 0xf

    let of_enum = function
      | i when (i < 0 || i > 0xf) -> None
      | 0                         -> Some Continuation
      | 1                         -> Some Text
      | 2                         -> Some Binary
      | 8                         -> Some Close
      | 9                         -> Some Ping
      | 10                        -> Some Pong
      | i when i < 8              -> Some (Nonctrl i)
      | i                         -> Some (Ctrl i)

    let to_enum = function
      | Continuation   -> 0
      | Text           -> 1
      | Binary         -> 2
      | Close          -> 8
      | Ping           -> 9
      | Pong           -> 10
      | Ctrl i         -> i
      | Nonctrl i      -> i

    let is_ctrl opcode = to_enum opcode > 7
  end

  type t = { opcode    : Opcode.t [@default Opcode.Text];
             extension : int [@default 0];
             final     : bool [@default true];
             content   : string [@default ""];
           } [@@deriving show,create]

  let of_bytes ?opcode ?extension ?final content =
    let content = Bytes.unsafe_to_string content in
    create ?opcode ?extension ?final ~content ()

  let close code =
    let content = Bytes.create 2 in
    EndianBytes.BigEndian.set_int16 content 0 code;
    of_bytes ~opcode:Opcode.Close content

  let of_subbytes ?opcode ?extension ?final content pos len =
    let content = Bytes.(sub content pos len |> unsafe_to_string) in
    create ?opcode ?extension ?final ~content ()
end

let xor mask msg =
  for i = 0 to Bytes.length msg - 1 do (* masking msg to send *)
    Bytes.set msg i Char.(code mask.[i mod 4] lxor code (Bytes.get msg i) |> chr)
  done

let read_uint16 ic =
  let buf = Bytes.create 2 in
  Lwt_io.read_into_exactly ic buf 0 2 >|= fun () ->
  EndianBytes.BigEndian.get_uint16 buf 0

let read_int64 ic =
  let buf = Bytes.create 8 in
  Lwt_io.read_into_exactly ic buf 0 8 >|= fun () ->
  EndianBytes.BigEndian.get_int64 buf 0

let write_int16 oc v =
  let buf = Bytes.create 2 in
  EndianBytes.BigEndian.set_int16 buf 0 v;
  Lwt_io.write oc (buf |> Bytes.unsafe_to_string)

let write_int64 oc v =
  let buf = Bytes.create 8 in
  EndianBytes.BigEndian.set_int64 buf 0 v;
  Lwt_io.write oc (buf |> Bytes.unsafe_to_string)

let is_bit_set idx v =
  (v lsr idx) land 1 = 1

let set_bit v idx b =
  if b then v lor (1 lsl idx) else v land (lnot (1 lsl idx))

let int_value shift len v = (v lsr shift) land ((1 lsl len) - 1)

let send_frame ~masked oc fr =
  let open Frame in
  let mask = random_string 4 in
  let content = Bytes.unsafe_of_string fr.content in
  let len = Bytes.length content in
  let opcode = Opcode.to_enum fr.opcode in
  let payload_len = match len with
    | n when n < 126      -> len
    | n when n < 1 lsl 16 -> 126
    | _                   -> 127 in
  let hdr = set_bit 0 15 (fr.final) in (* We do not support extensions for now *)
  let hdr = hdr lor (opcode lsl 8) in
  let hdr = set_bit hdr 7 masked in
  let hdr = hdr lor payload_len in (* Payload len is guaranteed to fit in 7 bits *)
  write_int16 oc hdr >>= fun () ->
  (match len with
   | n when n < 126        -> Lwt.return_unit
   | n when n < (1 lsl 16) -> write_int16 oc n
   | n                     -> Int64.of_int n |> write_int64 oc) >>= fun () ->
  (if masked && len > 0 then begin
      xor mask content;
      Lwt_io.write_from_exactly oc (Bytes.unsafe_of_string mask) 0 4
    end
   else Lwt.return_unit) >>= fun () ->
  Lwt_io.write_from_exactly oc content 0 len >>= fun () ->
  Lwt_io.flush oc

let make_read_frame ~masked react (ic,oc) =
  let open Frame in
  let hdr = Bytes.create 2 in
  let mask = Bytes.create 4 in
  let close_with_code code =
    let content = Bytes.create 2 in
    EndianBytes.BigEndian.set_int16 content 0 code;
    send_frame ~masked oc @@ Frame.close code >>= fun () ->
    Lwt.fail Exit in
  let react frame =
    match react frame with
    | Some resp -> Lwt.async (fun () -> send_frame ~masked oc resp)
    | None -> ()
  in
  fun () ->
    Lwt_io.read_into_exactly ic hdr 0 2 >>= fun () ->
    let hdr_part1 = EndianBytes.BigEndian.get_int8 hdr 0 in
    let hdr_part2 = EndianBytes.BigEndian.get_int8 hdr 1 in
    let final = is_bit_set 7 hdr_part1 in
    let extension = int_value 4 3 hdr_part1 in
    let opcode = int_value 0 4 hdr_part1 in
    let frame_masked = is_bit_set 7 hdr_part2 in
    let length = int_value 0 7 hdr_part2 in
    let opcode = Frame.Opcode.of_enum opcode |> CCOpt.get_exn in
    (match length with
     | i when i < 126 -> Lwt.return @@ Int64.of_int i
     | 126            -> read_uint16 ic >|= Int64.of_int
     | 127            -> read_int64 ic
     | _              -> assert false) >|= Int64.to_int >>= fun payload_len ->
    (if extension <> 0 then close_with_code 1002 else Lwt.return_unit) >>= fun () ->
    (if Opcode.is_ctrl opcode && payload_len > 125 then close_with_code 1002
     else Lwt.return_unit) >>= fun () ->
    (if frame_masked
     then Lwt_io.read_into_exactly ic mask 0 4
     else Lwt.return_unit) >>= fun () ->
    (* Create a buffer that will be passed to the push function *)
    let content = Bytes.create payload_len in
    Lwt_io.read_into_exactly ic content 0 payload_len >>= fun () ->
    let () = if frame_masked then xor (Bytes.unsafe_to_string mask) content in
    let frame = Frame.of_bytes ~opcode ~extension ~final content in
    Lwt_log.debug_f ~section "<- %s" (Frame.show frame) >>= fun () ->
    match opcode with

    | Opcode.Ping ->
      (* Immediately reply with a pong, and pass the message to
         the user *)
      react @@ Frame.of_bytes ~opcode ~extension ~final content;
      send_frame ~masked oc @@
      Frame.of_bytes ~opcode:Opcode.Pong ~extension ~final content

    | Opcode.Close ->
      (* Immediately echo and pass this last message to the user *)
      if payload_len >= 2 then begin
        react @@ Frame.of_bytes ~opcode ~extension ~final content;
        send_frame ~masked oc @@ Frame.of_subbytes ~opcode content 0 2 >>= fun () ->
        Lwt.fail Exit
      end
      else begin
        react @@ Frame.create ~opcode ~extension ~final ();
        send_frame ~masked oc @@ Frame.close 1000 >>= fun () ->
        Lwt.fail Exit
      end

    | Opcode.Pong
    | Opcode.Text
    | Opcode.Binary ->
      react @@ Frame.of_bytes ~opcode ~extension ~final content;
      Lwt.return_unit

    | _ ->
      send_frame ~masked oc @@ Frame.create ~opcode:Opcode.Close () >>= fun () ->
      Lwt.fail Exit

exception HTTP_Error of string

let is_upgrade =
  let open Re in
  let re = compile (seq [ rep any; no_case (str "upgrade") ]) in
  (function None -> false
          | Some(key) -> execp re key)

let with_connection ?tls_authenticator ?(extra_headers = []) uri react =
  (* Initialisation *)
  Lwt_unix.gethostname () >>= fun myhostname ->
  let host = CCOpt.get_exn (Uri.host uri) in
  let port = Uri.port uri in
  let scheme = Uri.scheme uri in
  X509_lwt.authenticator `No_authentication_I'M_STUPID >>= fun default_authenticator ->
  let port, tls_authenticator =
    match port, scheme with
    | None, None -> 80, tls_authenticator
    | Some p, None -> p, tls_authenticator
    | None, Some s -> (
        if s = "https" || s = "wss" then
          443, (if tls_authenticator = None
                then Some default_authenticator
                else tls_authenticator)
        else 80, tls_authenticator
      )
    | Some p, Some s ->
      if s = "https" || s = "wss" then
        p, Some default_authenticator
      else
        p, tls_authenticator
  in
  let connect () =
    let open Cohttp in
    let nonce = random_string ~base64:true 16 in
    let in_extra_hdrs key =
      let lkey = String.lowercase key in
      (List.find_all (fun (k,v) -> (String.lowercase k) = lkey) extra_headers) = [] in
    let hdr_list = extra_headers @ List.filter (fun (k,v) -> in_extra_hdrs k)
                     ["Upgrade"               , "websocket";
                      "Connection"            , "Upgrade";
                      "Sec-WebSocket-Key"     , nonce;
                      "Sec-WebSocket-Version" , "13"] in
    let headers = Header.of_list hdr_list in
    let req = Request.make ~headers uri in
    Lwt_io_ext.sockaddr_of_dns host (string_of_int port) >>= fun sockaddr ->
    let fd = Lwt_unix.socket
        (Unix.domain_of_sockaddr sockaddr) Unix.SOCK_STREAM 0 in
    Lwt_io_ext.set_tcp_nodelay fd;
    Lwt_unix.handle_unix_error
      (function
        | None -> Lwt_io_ext.open_connection ~fd sockaddr
        | Some tls_authenticator ->
          Lwt_io_ext.open_connection ~fd ~host ~tls_authenticator sockaddr)
      tls_authenticator >>= fun (ic, oc) ->
    let drain_handshake () =
      Lwt_unix.handle_unix_error
        (fun () -> CU.Request.write
            (fun writer -> Lwt.return_unit) req oc) () >>= fun () ->
      Lwt_unix.handle_unix_error CU.Response.read ic >>= (function
          | `Ok r -> Lwt.return r
          | `Eof -> Lwt.fail End_of_file
          | `Invalid s -> Lwt.fail @@ Failure s)
      >>= fun response ->
      let status = Response.status response in
      let headers = CU.Response.headers response in
      if Code.(is_error @@ code_of_status status)
      then Lwt.fail @@ HTTP_Error Code.(string_of_status status)
      else if not (Response.version response = `HTTP_1_1
                   && status = `Switching_protocols
                   && CCOpt.map String.lowercase @@
                   Header.get headers "upgrade" = Some "websocket"
                   && is_upgrade @@ C.Header.get headers "connection"
                   && Header.get headers "sec-websocket-accept" =
                      Some (nonce ^ websocket_uuid |> b64_encoded_sha1sum)
                  )
      then Lwt.fail_with "Protocol error"
      else Lwt_log.info_f ~section "Connected to %s" (Uri.to_string uri)
    in
    (try%lwt
      drain_handshake ()
     with exn ->
       Lwt_io_ext.(safe_close ic) >>= fun () ->
       Lwt.fail exn)
    >>= fun () ->
    Lwt.return (ic, oc)
  in
  connect () >|= fun (ic, oc) ->
  let read_frame = make_read_frame ~masked:true react (ic, oc) in
  let rec read_frames_forever () =
    (try%lwt
      read_frame ()
     with exn ->
       Lwt_io_ext.(safe_close ic) >>= fun () ->
       Lwt.fail exn)
    >>= read_frames_forever
  in
  Lwt.async read_frames_forever;
  send_frame ~masked:true oc

type server = Lwt_io_ext.server = { shutdown : unit Lazy.t }

let establish_server ?certificate ?buffer_size ?backlog sockaddr react =
  let id = ref 0 in
  let server_fun (ic, oc) =
    (CU.Request.read ic >>= function
      | `Ok r -> Lwt.return r
      | `Eof ->
        (* Remote endpoint closed connection. No further action necessary here. *)
        Lwt_log.info ~section "Remote endpoint closed connection" >>= fun () ->
        Lwt.fail End_of_file
      | `Invalid reason ->
        Lwt_log.info_f ~section "Invalid input from remote endpoint: %s" reason >>= fun () ->
        Lwt.fail @@ Failure reason) >>= fun request ->
    let meth    = C.Request.meth request in
    let version = C.Request.version request in
    let uri     = C.Request.uri request in
    let headers = C.Request.headers request in
    if not (
        version = `HTTP_1_1
        && meth = `GET
        && CCOpt.map String.lowercase @@
        C.Header.get headers "upgrade" = Some "websocket"
        && is_upgrade (C.Header.get headers "connection")
      )
    then Lwt.fail_with "Protocol error"
    else Lwt.return_unit >>= fun () ->
    let key = CCOpt.get_exn @@ C.Header.get headers "sec-websocket-key" in
    let hash = key ^ websocket_uuid |> b64_encoded_sha1sum in
    let response_headers = C.Header.of_list
        ["Upgrade", "websocket";
         "Connection", "Upgrade";
         "Sec-WebSocket-Accept", hash] in
    let response = C.Response.make
        ~status:`Switching_protocols
        ~encoding:C.Transfer.Unknown
        ~headers:response_headers () in
    CU.Response.write (fun writer -> Lwt.return_unit) response oc >>= fun () ->
    let read_frame = make_read_frame
        ~masked:false (react !id uri (send_frame ~masked:false oc)) (ic,oc) in
    incr id;
    let rec read_frames_forever () =
      read_frame ()
      >>= read_frames_forever
    in
    read_frames_forever ()
  in
  Lwt.async_exception_hook :=
    (fun exn -> Lwt_log.ign_warning ~section ~exn "async_exn_hook");
  Lwt_io_ext.establish_server
    ?certificate
    ~setup_clients_sockets:Lwt_io_ext.set_tcp_nodelay
    ?buffer_size ?backlog sockaddr
    (fun (ic,oc) ->
       (try%lwt
         server_fun (ic,oc)
        with
        | End_of_file ->
          Lwt_log.info ~section "Client closed connection"
        | Exit ->
          Lwt_log.info ~section "Server closed connection normally"
        | exn -> Lwt.fail exn
       ) [%finally Lwt_io_ext.safe_close ic]
    )
