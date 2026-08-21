#[tokio::main]
async fn main() {
    // 把 4097 -> 4098(反代注入认证)
    desktop_lib::proxy::spawn(4098, "test123".into(), 4102);
    println!("反代已启动: 127.0.0.1:4102 -> 127.0.0.1:4097");
    std::future::pending::<()>().await;
}
