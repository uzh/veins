let _ =
  Fixture.Db.query
    ~needs:Fixture.write
    (Fixture.Db.label_ctx ~role:Fixture.query Fixture.label)
    (fun _ -> Lwt_result.return ())
;;
