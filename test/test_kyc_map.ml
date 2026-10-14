open! Core
open Griffin_provider
open Banking_provider
module Model = Griffin_client.Model

let person : Kyc_core.Person.t =
  let open Kyc_core in
  { given_name = Pii.create "Ada"
  ; family_name = Pii.create "Example"
  ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:15)
  ; nationality = Pii.create (Country.of_string "GB")
  ; residential_address =
      Pii.create
        { Address.line1 = "10 Example Street"
        ; line2 = None
        ; city = "London"
        ; region = None
        ; postal_code = Some "NW1 6XE"
        ; country = Country.of_string "GB"
        }
  ; email = Pii.create "ada@example.com"
  ; mobile = Pii.create "+447700900000"
  }
;;

let%expect_test "a person becomes Griffin claims" =
  print_endline (Kyc_map.display_name person);
  List.iter (Kyc_map.person_claims person) ~f:(fun c ->
    print_endline (Yojson.Safe.to_string c));
  [%expect
    {|
    EXAMPLE, Ada
    {"claim-type":"individual-identity","given-name":"Ada","surname":"Example","date-of-birth":"1990-01-15"}
    {"claim-type":"contact-details","email-address":"ada@example.com"}
    {"claim-type":"individual-residence","building-number":"10","street-name":"Example Street","city":"London","country-code":"GB","postal-code":"NW1 6XE"}
    {"claim-type":"mobile-number","mobile-number":"+447700900000"}
    {"claim-type":"nationality","nationality":"GB"}
    |}];
  let abroad =
    { person with
      residential_address =
        Kyc_core.Pii.create
          { Kyc_core.Address.line1 = "Sepapaja 6"
          ; line2 = Some "Floor 2"
          ; city = "Tallinn"
          ; region = None
          ; postal_code = Some "11415"
          ; country = Kyc_core.Country.of_string "EE"
          }
    }
  in
  print_endline (Yojson.Safe.to_string (List.nth_exn (Kyc_map.person_claims abroad) 2));
  [%expect
    {| {"claim-type":"individual-residence","address-line-1":"Sepapaja 6","address-line-2":"Floor 2","city":"Tallinn","country-code":"EE","postal-code":"11415"} |}]
;;

let at = Fixture.time "2026-10-13T19:50:35Z"
let customer = Customer_ref.of_string "lp.fixture02xxxxxxxxxxxxx"

let%expect_test "an onboarded legal person with completed checks is approved" =
  let created = Fixture.load "legal-person-created" Model.Legal_person.t_of_yojson in
  let onboarded = Fixture.load "legal-person" Model.Legal_person.t_of_yojson in
  let verification = Fixture.load "verification" Model.Verification.t_of_yojson in
  let before = Kyc_map.kyc_status customer created ~latest_verification:None ~at in
  let running =
    Kyc_map.kyc_status
      customer
      ~previous:before
      created
      ~latest_verification:(Some { verification with verification_status = "in-progress" })
      ~at
  in
  let after =
    Kyc_map.kyc_status
      customer
      ~previous:running
      onboarded
      ~latest_verification:(Some verification)
      ~at
  in
  print_s [%sexp (before : Customer.Kyc_status.t)];
  print_s [%sexp (after : Customer.Kyc_status.t)];
  [%expect
    {|
    ((customer lp.fixture02xxxxxxxxxxxxx) (status Created) (tier T0)
     (steps
      ((Email Pending) (Mobile Pending) (Identity_document Pending)
       (Liveness Pending) (Address_proof Pending) (Source_of_funds Pending))))
    ((customer lp.fixture02xxxxxxxxxxxxx) (status Approved) (tier T0)
     (steps
      ((Email Pending) (Mobile Pending)
       (Identity_document (Verified "2026-10-13 19:50:35Z")) (Liveness Pending)
       (Address_proof (Verified "2026-10-13 19:50:35Z"))
       (Source_of_funds Pending))))
    |}];
  let show ~previous ~current =
    List.iter (Kyc_map.events ~previous ~current ~at) ~f:(fun (e : Event.t) ->
      print_s [%sexp (e.id : Event_id.t), (e.kind : Event.Kind.t)])
  in
  show ~previous:before ~current:running;
  show ~previous:running ~current:after;
  [%expect
    {|
    (kyc:lp.fixture02xxxxxxxxxxxxx:step:Identity_document:Sent
     (Kyc (customer lp.fixture02xxxxxxxxxxxxx)
      (update (Step (step Identity_document) (state Sent)))))
    (kyc:lp.fixture02xxxxxxxxxxxxx:step:Address_proof:Sent
     (Kyc (customer lp.fixture02xxxxxxxxxxxxx)
      (update (Step (step Address_proof) (state Sent)))))
    (kyc:lp.fixture02xxxxxxxxxxxxx:Created:Submit
     (Kyc (customer lp.fixture02xxxxxxxxxxxxx) (update (Status Submit))))
    (kyc:lp.fixture02xxxxxxxxxxxxx:step:Identity_document:Verified
     (Kyc (customer lp.fixture02xxxxxxxxxxxxx)
      (update
       (Step (step Identity_document) (state (Verified "2026-10-13 19:50:35Z"))))))
    (kyc:lp.fixture02xxxxxxxxxxxxx:step:Address_proof:Verified
     (Kyc (customer lp.fixture02xxxxxxxxxxxxx)
      (update
       (Step (step Address_proof) (state (Verified "2026-10-13 19:50:35Z"))))))
    (kyc:lp.fixture02xxxxxxxxxxxxx:Verifying:Approve
     (Kyc (customer lp.fixture02xxxxxxxxxxxxx) (update (Status Approve))))
    |}]
;;

let%expect_test "a declined decision rejects with its notes" =
  let lp = Fixture.load "legal-person" Model.Legal_person.t_of_yojson in
  let declined =
    { lp with
      latest_decision =
        Option.map lp.latest_decision ~f:(fun d ->
          { d with decision_outcome = "declined"; decision_notes = Some "sanctions hit" })
    }
  in
  print_s
    [%sexp (Kyc_map.status declined ~latest_verification:None : Kyc_core.Status.t)];
  print_s
    [%sexp
      (Kyc_map.transitions ~from:Created ~to_:(Rejected "x")
       : Kyc_core.Status.Transition.t list)];
  [%expect
    {|
    (Rejected "sanctions hit")
    (Submit (Reject x))
    |}]
;;

let%test_unit "events replay a status change in kyc-core order" =
  (* Applying the published transitions to the previous status always reaches the new one
     when a path exists. *)
  let statuses : Kyc_core.Status.t list =
    [ Created; Verifying; Approved; Rejected "declined" ]
  in
  List.iter statuses ~f:(fun from ->
    List.iter statuses ~f:(fun to_ ->
      let trs = Kyc_map.transitions ~from ~to_ in
      if not (List.is_empty trs)
      then (
        let reached =
          List.fold trs ~init:from ~f:(fun s tr ->
            Kyc_core.Status.apply s tr ~actor:(Provider "griffin") |> Or_error.ok_exn)
        in
        [%test_result: Kyc_core.Status.t] reached ~expect:to_)))
;;
