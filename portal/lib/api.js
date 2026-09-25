import { NextResponse } from 'next/server';

export function withApiError(handler) {
  return async function routeHandler(request, context) {
    try {
      return await handler(request, context);
    } catch (error) {
      // Errors raised deliberately by the route (401, 400, …).
      if (typeof error?.status === 'number') {
        return NextResponse.json(
          { error: error.message },
          { status: error.status }
        );
      }

      const message =
        error instanceof Error ? error.message : 'Unexpected server error';

      const isConfigError =
        typeof message === 'string' &&
        (message.includes('MONGODB_URI') || message.includes('AUTH_SECRET'));

      return NextResponse.json(
        {
          error: isConfigError
            ? message
            : `Database request failed: ${message}`,
        },
        { status: isConfigError ? 503 : 500 }
      );
    }
  };
}
