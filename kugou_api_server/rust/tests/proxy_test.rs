//! /audio/proxy 端点回归测试（本地可跑，无需真机）。
//! 用例数据来自 2026-09-22 iOS 诊断日志：gzip 解压后 Content-Length 不匹配
//! 曾导致 AVPlayer -11828 "Cannot Open"。

use std::io::{Read, Write};
use std::net::TcpStream;

fn http_get(port: u16, path: &str, range: Option<&str>) -> (u16, Vec<(String, String)>, Vec<u8>) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    let range_hdr = range.map(|r| format!("Range: {}\r\n", r)).unwrap_or_default();
    write!(
        stream,
        "GET {} HTTP/1.1\r\nHost: 127.0.0.1\r\n{}Connection: close\r\n\r\n",
        path, range_hdr
    )
    .unwrap();
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).unwrap();
    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("header end");
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.lines();
    let status: u16 = lines
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| {
            l.split_once(':')
                .map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_string()))
        })
        .collect();
    let raw_body = &buf[header_end + 4..];
    // chunked 响应需解帧（tiny_http 在无 content-length 时走 chunked）
    let body = if headers
        .iter()
        .any(|(k, v)| k == "transfer-encoding" && v.to_lowercase().contains("chunked"))
    {
        let mut out = Vec::new();
        let mut i = 0;
        while i < raw_body.len() {
            let line_end = raw_body[i..]
                .windows(2)
                .position(|w| w == b"\r\n")
                .expect("chunk size line end")
                + i;
            let size = usize::from_str_radix(
                String::from_utf8_lossy(&raw_body[i..line_end])
                    .split(';')
                    .next()
                    .unwrap()
                    .trim(),
                16,
            )
            .unwrap();
            if size == 0 {
                break;
            }
            out.extend_from_slice(&raw_body[line_end + 2..line_end + 2 + size]);
            i = line_end + 2 + size + 2; // 跳过 chunk 数据与随后的 CRLF
        }
        out
    } else {
        raw_body.to_vec()
    };
    (status, headers, body)
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

#[test]
fn proxy_streams_kugou_content_and_range() {
    let tmp = std::env::temp_dir().join(format!("kugou_proxy_test_{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let port = kugou_server::server::start(0, tmp.to_str().unwrap().to_string())
        .expect("server start");
    assert!(port > 0);

    // 诊断日志里出现过的真实酷狗 URL（图片，音视频同代理路径）
    let target = "http://imge.kugou.com/stdmusic/400/20260416/20260416153631268600.jpg";
    let encoded = target.replace(':', "%3A").replace('/', "%2F");
    let path = format!("/audio/proxy?url={}", encoded);

    // 完整请求：200 + 图像字节 + 长度一致
    let (status, headers, body) = http_get(port, &path, None);
    assert_eq!(status, 200, "proxy full GET should be 200");
    assert_eq!(body[..2], [0xFF, 0xD8], "should be JPEG magic bytes");
    if let Some(len) = header(&headers, "content-length") {
        assert_eq!(
            len.parse::<usize>().unwrap(),
            body.len(),
            "Content-Length must match actual streamed bytes (gzip decompression bug)"
        );
    }

    // Range 请求：206 + Content-Range 透传（AVPlayer 拖进度依赖）
    let (status2, headers2, body2) = http_get(port, &path, Some("bytes=0-99"));
    assert_eq!(status2, 206, "range GET should be 206");
    assert_eq!(body2.len(), 100, "range length should be 100");
    assert!(
        header(&headers2, "content-range").is_some(),
        "content-range must be passthrough"
    );

    // 非酷狗域名拒绝
    let bad = "/audio/proxy?url=http%3A%2F%2Fexample.com%2Fa.mp3";
    let (status3, _, _) = http_get(port, bad, None);
    assert_eq!(status3, 403, "non-kugou host must be rejected");

    kugou_server::stop_server();
    let _ = std::fs::remove_dir_all(&tmp);
}
