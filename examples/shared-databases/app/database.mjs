import knex from "knex"
import { fileURLToPath } from "node:url"

export function connect(database = process.env.DB_NAME) {
  const isPostgres = process.env.DB_ENGINE === "postgres"
  const connection = {
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database,
  }

  if (!isPostgres) {
    connection.options = { encrypt: true, trustServerCertificate: true }
  }

  return knex({
    client: isPostgres ? "pg" : "mssql",
    connection,
    pool: { min: 0, max: 2 },
    acquireConnectionTimeout: 10000,
  })
}

// The consumer owns schema changes, not server/database/login provisioning.
// Knex records completed migrations and serializes concurrent app/test startup.
export async function migrate(database) {
  const directory = fileURLToPath(new URL("./migrations", import.meta.url))
  await database.migrate.latest({ directory })
}
