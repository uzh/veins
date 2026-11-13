let _ =
  Fixture.Db.exec
    (Fixture.Db.label_ctx ~role:Fixture.query Fixture.label)
    Fixture.insert
    1
;;
