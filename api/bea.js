// Vercel serverless function — proxies BEA API requests to avoid browser CORS.
// Flutter web calls /api/bea?method=GetData&... (same origin).
// This function injects the BEA_API_KEY server-side and forwards to BEA.
export default async function handler(req, res) {
  const params = new URLSearchParams(req.query);

  // Inject the real key server-side — never trust the client-supplied UserID
  params.set('UserID', process.env.BEA_API_KEY ?? '');
  params.set('ResultFormat', 'JSON');

  const url = `https://apps.bea.gov/api/data?${params.toString()}`;

  try {
    const upstream = await fetch(url);
    const body = await upstream.json();

    res.setHeader('Content-Type', 'application/json');
    res.status(upstream.status).json(body);
  } catch (err) {
    res.status(502).json({ error: `BEA proxy error: ${err.message}` });
  }
}
