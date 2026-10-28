use fizz::phone::handle;
use vercel_runtime::{Error, Request, Response, ResponseBody, run, service_fn};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(request: Request) -> Result<Response<ResponseBody>, Error> {
    if let Err(response) = fizz::security::guard_request(&request) {
        return Ok(response);
    }
    Ok(handle(request).await)
}
