import json

import azure.functions as func

from policy_enrichment import enrich_batch

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"status": "ok"}),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="policy-applicability", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def policy_applicability(req: func.HttpRequest) -> func.HttpResponse:
    # App Service Easy Auth validates the Entra token before this keyless trigger runs.
    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Request body must be valid JSON"}),
            status_code=400,
            mimetype="application/json",
        )

    if not isinstance(payload, dict) or not isinstance(payload.get("values"), list):
        return func.HttpResponse(
            json.dumps({"error": "Request must contain a top-level values list"}),
            status_code=400,
            mimetype="application/json",
        )

    return func.HttpResponse(
        json.dumps(enrich_batch(payload["values"]), ensure_ascii=False),
        status_code=200,
        mimetype="application/json",
    )