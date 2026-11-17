exports.up = async (database) => {
  await database.schema.createTable("notes", (table) => {
    table.increments("id").primary()
    table.string("body", 200).notNullable()
  })
}

exports.down = async (database) => {
  await database.schema.dropTable("notes")
}
