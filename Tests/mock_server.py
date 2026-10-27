"""Local UI test fixture; produces labeled canned replies, not real translations."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 1_000_000:
            self.send_error(413)
            return
        try:
            payload = json.loads(self.rfile.read(size))
            assert payload["model"] == "local-test"
            messages = payload["messages"]
            assert messages[0]["role"] == "system"
        except (ValueError, KeyError, IndexError, AssertionError):
            self.send_error(400)
            return
        text = "OK" if messages[-1]["content"] == "Connection test" else "本地界面测试响应（非真实翻译）"
        data = json.dumps({"choices": [{"message": {"content": text}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 18943), Handler)
    print("Local UI fixture listening on 127.0.0.1:18943", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
