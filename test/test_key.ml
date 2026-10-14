open! Core
module Sig = Griffin_client.Http_signature

let unhex s = Cryptokit.transform_string (Cryptokit.Hexa.decode ()) s

let d =
  unhex
    "01101adf61e9fd0c620827ede08ef63e993c0371c6239f30db45d52797392568c9fb93ceb125cbc4d9df66c26933e7987ee655a887d4cdec0220b206811ff6217c23"
;;

let x =
  unhex
    "0140f6ba272ff2d1416b645f21412e33cd5bd15ba62a90499ca819c6237b884d071574cc3694c397d3fa79cf4c3b8e8840591394b3b43c8012fce09d0d4d914b9e43"
;;

let y =
  unhex
    "00e1b0bf8bfb23f3d2f15f8dbb64e5890edbbb16ab8eabcfe2f969b097bd8419742cf6d152ff4dd51c7592301f90855a51645dcc523b9fa74aa77f7f9ed0136da5c5"
;;

let kid = "griffin-test-1"
let b64url s = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let components =
  [ "date"
  ; "@method"
  ; "@path"
  ; "@authority"
  ; "content-type"
  ; "content-length"
  ; "content-digest"
  ]
;;

let sign_delivery ~authority ~path ~body =
  let now = Time_ns.now () in
  let created = Time_ns.to_int_ns_since_epoch now / 1_000_000_000 in
  let headers =
    [ "date", Sig.http_date now
    ; "content-type", "application/json"
    ; "content-length", Int.to_string (String.length body)
    ; "content-digest", Sig.content_digest body
    ]
  in
  let params =
    sprintf
      {|(%s);created=%d;expires=%d;nonce="%s";keyid="%s"|}
      (String.concat ~sep:" " (List.map components ~f:(sprintf "%S")))
      created
      (created + 300)
      (Sig.uuid_v4 ())
      kid
  in
  let base =
    Sig.signature_base
      { Sig.Message.meth = "POST"; authority; path; query = None; headers; body }
      ~components
      ~params
    |> Or_error.ok_exn
  in
  (* A fixed nonce [k] is fine for a test key; never for a real one. *)
  let signature =
    Griffin_client.P521.For_testing.sign ~d ~k:(String.make 65 '\003') base
  in
  headers
  @ [ "signature-input", sprintf "%s=%s" kid params
    ; "signature", sprintf "%s=:%s:" kid (Base64.encode_exn signature)
    ]
;;
