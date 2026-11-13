let _ =
  Fixture.Db.populate
    ~needs:Fixture.write
    (Fixture.Db.label_ctx ~role:Fixture.query Fixture.label)
    "t"
    [ "id" ]
    Caqti_type.int
    [ 1 ]
;;
