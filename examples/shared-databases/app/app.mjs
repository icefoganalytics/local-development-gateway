import { createServer } from "node:http"
import { once } from "node:events"

import { connect, migrate } from "./database.mjs"

const command = process.argv[2] ?? "serve"

if (command === "note") {
  const response = await fetch(`http://${process.env.APP_HOST}:3000/notes`, {
    method: "POST",
    body: process.argv[3],
  })

  if (!response.ok) {
    const message = await response.text()
    throw new Error(message)
  }

  console.log(await response.text())
} else {
  const database = connect()
  let isServing = false

  try {
    if (command === "query") {
      const result = await database.raw(process.argv[3])
      console.log(JSON.stringify(result))
    } else if (command === "migrate") {
      await migrate(database)
    } else if (command === "serve") {
      await migrate(database)

      const server = createServer(async (request, response) => {
        try {
          if (request.url !== "/notes") {
            response.writeHead(404).end()
            return
          }

          if (request.method === "POST") {
            let body = ""

            for await (const chunk of request) {
              body += chunk

              if (body.length > 200) {
                break
              }
            }

            if (!body.trim() || body.length > 200) {
              response.writeHead(400).end("Note must contain 1–200 characters")
              return
            }

            await database("notes").insert({ body })
          } else if (request.method !== "GET") {
            response.writeHead(405).end()
            return
          }

          const notes = await database("notes").select("id", "body").orderBy("id")

          response.setHeader("Content-Type", "application/json")
          response.end(JSON.stringify(notes))
        } catch (error) {
          console.error(error)
          response.writeHead(500).end("Database operation failed")
        }
      })

      server.listen(3000, "0.0.0.0")
      await once(server, "listening")
      isServing = true

      for (const signal of ["SIGINT", "SIGTERM"]) {
        process.once(signal, () => {
          server.close(async () => {
            await database.destroy()
          })
        })
      }
    } else {
      throw new Error(`Unknown application command: ${command}`)
    }
  } finally {
    if (!isServing) {
      await database.destroy()
    }
  }
}
