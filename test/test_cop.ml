open! Core
open Griffin_provider
module Model = Griffin_client.Model

let%expect_test "Confirmation of Payee answers as payee checks" =
  List.iter [ "cop-match"; "cop-close-match"; "cop-no-match" ] ~f:(fun name ->
    let r = Fixture.load name Model.Cop_request.t_of_yojson in
    print_s
      [%sexp
        (name : string)
        , (Adapter.payee_check r.cop_response : Payments_core.Beneficiary.Payee_check.t)]);
  [%expect
    {|
    (cop-match Match)
    (cop-close-match (Close_match (suggested_name "Example Payee CloseMatch")))
    (cop-no-match No_match)
    |}]
;;
