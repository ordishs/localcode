import http from 'node:http'
import fs from 'node:fs'

const body = fs.readFileSync(process.argv[2])

http
  .createServer((req, res) => {
    if (req.url === '/v1/models' && req.headers.authorization === 'Bearer fake-token') {
      res.setHeader('content-type', 'application/json')
      res.end(body)
      return
    }

    res.statusCode = 401
    res.end('{"error":{"message":"bad token"}}')
  })
  .listen(0, '127.0.0.1', function () {
    fs.writeFileSync(process.argv[3], String(this.address().port))
  })
