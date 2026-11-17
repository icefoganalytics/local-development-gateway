import assert from "node:assert/strict"
import { after, before, beforeEach, test } from "node:test"

import { connect, migrate } from "./database.mjs"

// Never let a test cleanup command use development or administrator credentials.
assert.match(process.env.DB_NAME, /^app_[a-z][a-z0-9_]{0,31}_test$/)
assert.equal(process.env.DB_USER, process.env.DB_NAME)
const database = connect()

before(async () => {
  await migrate(database)
})

beforeEach(async () => {
  await database("notes").del()
})

after(async () => {
  try {
    await database("notes").del()
  } finally {
    await database.destroy()
  }
})

test("when using checkout test credentials, persists and reads a note", async () => {
  // Arrange
  await database("notes").insert({ body: "consumer test" })

  // Act
  const notes = await database("notes").select("body")

  // Assert
  assert.deepEqual(notes, [{ body: "consumer test" }])
})

test("when test credentials access development, denies the connection", async () => {
  // Arrange
  const developmentName = process.env.DB_NAME.replace(/_test$/, "_development")
  const isPostgres = process.env.DB_ENGINE === "postgres"
  const development = isPostgres ? connect(developmentName) : connect()
  try {
    const query = isPostgres ? "SELECT 1" : `USE [${developmentName}]; SELECT DB_NAME();`

    // Act
    const result = development.raw(query)

    // Assert
    await assert.rejects(result, (error) => {
      assert.match(error.message, /permission denied for database|Cannot open database|not able to access the database/i)
      return true
    })
  } finally {
    await development.destroy()
  }
})
