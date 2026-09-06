import { Container } from "@cloudflare/containers";

export class SprtsContainer extends Container<Env> {
  defaultPort = 8080;
  requiredPorts = [8080];
  sleepAfter = "10m";
  enableInternet = true;
  pingEndpoint = "/healthz";
  envVars = {
    PORT: "8080",
    SPRTS_HOST: "0.0.0.0",
  };

  override onStart(): void {
    console.log(JSON.stringify({ message: "sprts container started" }));
  }

  override onStop(): void {
    console.log(JSON.stringify({ message: "sprts container stopped" }));
  }

  override onError(error: unknown): void {
    console.error(
      JSON.stringify({
        message: "sprts container error",
        error: error instanceof Error ? error.message : String(error),
      }),
    );
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const container = env.SPRTS_CONTAINER.getByName("primary");
      return await container.fetch(request);
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "sprts request failed",
          error: error instanceof Error ? error.message : String(error),
          path: new URL(request.url).pathname,
        }),
      );
      return Response.json(
        { error: "service temporarily unavailable" },
        { status: 503 },
      );
    }
  },
} satisfies ExportedHandler<Env>;

