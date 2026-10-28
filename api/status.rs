use fizz::store::{ConnectionError, Supabase};
use serde_json::json;
use vercel_runtime::{Error, Request, Response, ResponseBody, run, service_fn};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(request: Request) -> Result<Response<ResponseBody>, Error> {
    if let Err(response) = fizz::security::guard_request(&request) {
        return Ok(response);
    }
    if request.method() != "GET" {
        return Ok(fizz::customer::error(405, "method_not_allowed", "Use GET."));
    }
    let database = match Supabase::from_env() {
        Ok(supabase) => match supabase.check_connection().await {
            Ok(()) => "connected",
            Err(_) => "unavailable",
        },
        Err(ConnectionError::MissingConfiguration) => "unconfigured",
        Err(_) => "unavailable",
    };
    Ok(fizz::customer::reply(
        200,
        json!({
            "service": "fizz",
            "status": if database == "connected" { "ok" } else { "degraded" },
            "database": database,
            "description": "The physical layer for AI agents"
        }),
        None,
    ))
}
