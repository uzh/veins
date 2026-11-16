let _ =
  Fixture.Db.transaction_ctx ~role:Fixture.query Fixture.label (fun ctx ->
    Fixture.Db.with_transaction ctx (fun inner -> Fixture.Db.exec inner Fixture.insert 1))
;;
