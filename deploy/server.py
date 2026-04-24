import http.server

class Utf8Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        # 调用父类方法获取文件句柄或处理目录生成
        path = self.translate_path(self.path)
        import os
        
        # 如果是目录，强制指定 Content-Type 为 text/html
        if os.path.isdir(path):
            f = super().list_directory(path)
            if f:
                # 关键：手动构造包含编码的 Header
                self.send_response(200)
                self.send_header("Content-type", "text/html; charset=utf-8")
                self.end_headers()
            return f
        
        return super().send_head()

    def end_headers(self):
        # 仅对文件生效，避免干扰 list_directory 的头部发送
        mimetype = self.guess_type(self.path)
        if mimetype:
            self.send_header("Content-Type", f"{mimetype}; charset=utf-8")
        super().end_headers()

if __name__ == "__main__":
    http.server.test(HandlerClass=Utf8Handler, port=8000)
