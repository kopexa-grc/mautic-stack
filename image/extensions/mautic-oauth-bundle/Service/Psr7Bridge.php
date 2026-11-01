<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Service;

use GuzzleHttp\Psr7\Response as PsrResponse;
use GuzzleHttp\Psr7\ServerRequest;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/** Minimal HttpFoundation <-> PSR-7 conversion for league/oauth2-server. */
class Psr7Bridge
{
    /**
     * @param array<string, mixed>|null $query override the query parameters
     */
    public function toPsr(Request $request, ?array $query = null): ServerRequestInterface
    {
        $psr = new ServerRequest(
            $request->getMethod(),
            $request->getUri(),
            $request->headers->all(),
            $request->getContent(),
            $request->getProtocolVersion() ? substr($request->getProtocolVersion(), 5) : '1.1',
            $request->server->all()
        );

        return $psr->withQueryParams($query ?? $request->query->all())
            ->withParsedBody($request->request->all())
            ->withCookieParams($request->cookies->all());
    }

    public function newResponse(): ResponseInterface
    {
        return new PsrResponse();
    }

    public function toSymfony(ResponseInterface $psr): Response
    {
        $response = new Response((string) $psr->getBody(), $psr->getStatusCode());
        foreach ($psr->getHeaders() as $name => $values) {
            $response->headers->set($name, $values);
        }

        return $response;
    }
}
