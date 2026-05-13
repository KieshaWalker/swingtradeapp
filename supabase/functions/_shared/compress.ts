// Wraps a JSON response with gzip compression when the client supports it.
// Cuts typical payload size by 60–80% at zero cost to the caller.
export async function jsonResponse(
  req: Request,
  data: unknown,
  extraHeaders: Record<string, string> = {},
  status = 200,
): Promise<Response> {
  const body   = JSON.stringify(data)
  const accept = req.headers.get('Accept-Encoding') ?? ''

  if (accept.includes('gzip')) {
    const bytes  = new TextEncoder().encode(body)
    const stream = new CompressionStream('gzip')
    const writer = stream.writable.getWriter()
    writer.write(bytes)
    writer.close()
    return new Response(stream.readable, {
      status,
      headers: {
        ...extraHeaders,
        'Content-Type':     'application/json',
        'Content-Encoding': 'gzip',
        'Vary':             'Accept-Encoding',
      },
    })
  }

  return new Response(body, {
    status,
    headers: { ...extraHeaders, 'Content-Type': 'application/json' },
  })
}
