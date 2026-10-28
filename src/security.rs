//! Shared browser request boundaries. Bearer-token devices may omit Origin.
use std::env;

use reqwest::Url;
use vercel_runtime::{Response, ResponseBody};

use crate::{customer::error, store::Supabase};

pub fn site_origin(host: Option<&str>) -> Option<String> {
    let host = host?;
    if host.is_empty()
        || host
            .bytes()
            .any(|c| !c.is_ascii_alphanumeric() && !b".-:[]".contains(&c))
    {
        return None;
    }
    let parsed = Url::parse(&format!("https://{host}")).ok()?;
    let local = matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    let configured = [
        "VERCEL_URL",
        "VERCEL_BRANCH_URL",
        "VERCEL_PROJECT_PRODUCTION_URL",
    ]
    .iter()
    .filter_map(|key| env::var(key).ok())
    .any(|value| value.eq_ignore_ascii_case(host));
    if !local
        && !configured
        && !matches!(
            host,
            "fizzlayer.com" | "www.fizzlayer.com" | "fizz-zeta.vercel.app"
        )
    {
        return None;
    }
    let mut origin = parsed;
    if local {
        origin.set_scheme("http").ok()?;
    }
    Some(origin.origin().ascii_serialization())
}

pub fn guard_request<B>(request: &http::Request<B>) -> Result<(), Response<ResponseBody>> {
    let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok());
    // Never use client-supplied x-forwarded-host to authorize an origin.
    let Some(expected) =
        site_origin(header("host").or_else(|| request.uri().authority().map(|a| a.as_str())))
    else {
        return Err(error(
            400,
            "invalid_host",
            "Request host is not configured.",
        ));
    };
    if request.headers().contains_key("origin") && header("origin") != Some(expected.as_str()) {
        return Err(error(
            403,
            "forbidden_origin",
            "Request origin is not allowed.",
        ));
    }
    if !matches!(request.method().as_str(), "GET" | "HEAD" | "OPTIONS")
        && header("sec-fetch-site").is_some_and(|site| !matches!(site, "same-origin" | "none"))
    {
        return Err(error(403, "forbidden_origin", "Use this site's own pages."));
    }
    Ok(())
}

pub fn is_json(content_type: &str) -> bool {
    content_type
        .split(';')
        .next()
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
}

/// Validate the session and consume a database-backed budget before paid work.
pub async fn paid_request_budget(
    store: &Supabase,
    token: &str,
    operation: &str,
) -> Result<(), Response<ResponseBody>> {
    let value = store
        .rpc(
            "fizz_request_budget",
            serde_json::json!({"p_token": token, "p_operation": operation}),
        )
        .await;
    match value {
        Ok(value) if value["ok"] == true => Ok(()),
        Ok(value) if value["error"] == "unauthorized" => {
            Err(error(401, "unauthorized", "Sign in to continue."))
        }
        Ok(value) if value["error"] == "rate_limited" => {
            let mut response = error(429, "rate_limited", "Usage limit reached. Try again later.");
            response
                .headers_mut()
                .insert("retry-after", "60".parse().expect("valid header"));
            Err(response)
        }
        _ => Err(error(
            503,
            "unavailable",
            "Usage checks are temporarily unavailable.",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(host: &str, origin: Option<&str>, site: Option<&str>) -> http::Request<()> {
        let mut builder = http::Request::builder()
            .method("POST")
            .uri("/api/sensors")
            .header("host", host);
        if let Some(origin) = origin {
            builder = builder.header("origin", origin);
        }
        if let Some(site) = site {
            builder = builder.header("sec-fetch-site", site);
        }
        builder.body(()).unwrap()
    }

    #[test]
    fn browser_and_device_origin_boundaries() {
        assert!(
            guard_request(&request(
                "fizzlayer.com",
                Some("https://fizzlayer.com"),
                Some("same-origin")
            ))
            .is_ok()
        );
        assert!(guard_request(&request("fizzlayer.com", None, None)).is_ok());
        for origin in [
            "https://evil.example",
            "https://evil.fizzlayer.com",
            "null",
            "http://fizzlayer.com",
        ] {
            assert!(guard_request(&request("fizzlayer.com", Some(origin), None)).is_err());
        }
        assert!(guard_request(&request("fizzlayer.com", None, Some("cross-site"))).is_err());
        assert!(guard_request(&request("fizzlayer.com", None, Some("same-site"))).is_err());
        assert!(
            guard_request(&request("evil.example", Some("https://evil.example"), None)).is_err()
        );
        let mut forged = request("fizzlayer.com", Some("https://evil.example"), None);
        forged
            .headers_mut()
            .insert("x-forwarded-host", "evil.example".parse().unwrap());
        assert!(guard_request(&forged).is_err());
    }

    #[test]
    fn localhost_is_exact_and_json_media_types_are_exact() {
        assert_eq!(
            site_origin(Some("localhost:3000")).as_deref(),
            Some("http://localhost:3000")
        );
        for host in [
            "localhost.evil.com",
            "127.0.0.1.evil.com",
            "evil.com/path",
            "fizzlayer.com:444",
        ] {
            assert!(site_origin(Some(host)).is_none(), "{host}");
        }
        assert!(is_json("application/json; charset=utf-8"));
        assert!(is_json("Application/JSON"));
        assert!(!is_json("application/jsonp"));
        assert!(!is_json("text/plain"));
    }
}
