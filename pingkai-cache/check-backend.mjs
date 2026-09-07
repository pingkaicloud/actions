#!/usr/bin/env node
// Preflight check for the pingkai-cache backend: one signed ListObjectsV2
// (max-keys=1) call before any real work runs, so deterministic
// misconfigurations (bad credentials, missing bucket, insufficient policy)
// fail the job in seconds instead of degrading into a silent cold build.
//
// Exit codes:
//   0 - backend verified, or a transient issue downgraded to ::warning::
//       (keeps the cache best-effort semantics)
//   1 - deterministic configuration error; retrying cannot help
//
// Runs with the runner's bundled Node (>=18): fetch + node:crypto only.

import { createHash, createHmac } from "node:crypto";

const endpoint = process.env.PINGKAI_CACHE_CHECK_ENDPOINT || "";
const bucket = process.env.PINGKAI_CACHE_BUCKET || "";
const region = process.env.PINGKAI_CACHE_REGION || "cn-shanghai";
const accessKey = process.env.AWS_ACCESS_KEY_ID || "";
const secretKey = process.env.AWS_SECRET_ACCESS_KEY || "";
const pathStyle = (process.env.PINGKAI_CACHE_PATH_STYLE || "false") === "true";

const fail = (msg) => {
  console.error(`::error::${msg}`);
  process.exit(1);
};
const warn = (msg) => {
  console.log(`::warning::${msg}`);
  process.exit(0);
};

if (!endpoint || !bucket || !accessKey || !secretKey) {
  fail("preflight is missing endpoint/bucket/credential inputs; this is a pingkai-cache bug, please report it");
}

const sha256Hex = (data) => createHash("sha256").update(data).digest("hex");
const hmac = (key, data) => createHmac("sha256", key).update(data).digest();

let url;
try {
  url = new URL(endpoint);
} catch (e) {
  fail(`endpoint is not a valid URL after normalization: ${endpoint} (${e.message})`);
}
url.pathname = pathStyle ? `/${bucket}/` : "/";
if (!pathStyle) {
  url.host = `${bucket}.${url.host}`;
}
// Canonical (sorted) query order: list-type < max-keys < prefix.
url.search = new URLSearchParams({
  "list-type": "2",
  "max-keys": "1",
  prefix: "cache/",
}).toString();

const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
const dateStamp = amzDate.slice(0, 8);
const payloadHash = sha256Hex("");
const canonicalHeaders =
  `host:${url.host}\n` +
  `x-amz-content-sha256:${payloadHash}\n` +
  `x-amz-date:${amzDate}\n`;
const signedHeaders = "host;x-amz-content-sha256;x-amz-date";
const canonicalRequest = [
  "GET",
  url.pathname,
  url.search.slice(1),
  canonicalHeaders,
  signedHeaders,
  payloadHash,
].join("\n");
const scope = `${dateStamp}/${region}/s3/aws4_request`;
const stringToSign = [
  "AWS4-HMAC-SHA256",
  amzDate,
  scope,
  sha256Hex(canonicalRequest),
].join("\n");
const kSigning = hmac(
  hmac(hmac(hmac(`AWS4${secretKey}`, dateStamp), region), "s3"),
  "aws4_request"
);
const signature = createHmac("sha256", kSigning).update(stringToSign).digest("hex");

let res;
try {
  res = await fetch(url, {
    method: "GET",
    headers: {
      "x-amz-date": amzDate,
      "x-amz-content-sha256": payloadHash,
      Authorization: `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    },
    signal: AbortSignal.timeout(8000),
  });
} catch (e) {
  const reason = e.cause?.code || e.name || e.message;
  warn(`cache backend preflight could not reach ${url.origin} (${reason}); continuing, cache stays best-effort`);
}

const body = await res.text().catch(() => "");
const errCode = (body.match(/<Code>([^<]+)<\/Code>/) || [])[1] || "";

if (res.status === 200) {
  console.log(`::notice::cache backend preflight OK: ${url.origin} accepted a signed ListObjectsV2`);
  process.exit(0);
}

const hints = {
  InvalidAccessKeyId:
    "the access key id is unknown to this backend - check the PINGKAI_CACHE_ACCESS_KEY_ID secret",
  SignatureDoesNotMatch:
    "signature rejected - wrong secret access key, or this backend does not accept AWS SigV4",
  AccessDenied:
    "credentials are valid but lack ListObjects permission on the bucket - check the RAM policy",
  NoSuchBucket: "the bucket does not exist on this endpoint",
};
if (res.status === 403 || res.status === 404) {
  const hint = hints[errCode] || `backend rejected the request (code=${errCode || "unknown"})`;
  fail(`cache backend preflight failed: ${hint}. Retrying will not help - fix the PINGKAI_CACHE_* configuration.`);
}
warn(`cache backend preflight got HTTP ${res.status} (code=${errCode || "unknown"}) from ${url.origin}; continuing, cache stays best-effort`);
