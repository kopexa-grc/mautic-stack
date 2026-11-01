<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Controller;

use Defuse\Crypto\Crypto;
use League\OAuth2\Server\Exception\OAuthServerException;
use MauticPlugin\KopexaOAuthBundle\Repository\ClientRepository;
use MauticPlugin\KopexaOAuthBundle\Repository\GrantRepository;
use MauticPlugin\KopexaOAuthBundle\Service\Psr7Bridge;
use MauticPlugin\KopexaOAuthBundle\Service\RedirectUriPolicy;
use MauticPlugin\KopexaOAuthBundle\Service\ServerFactory;
use MauticPlugin\KopexaOAuthBundle\Service\Settings;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Generator\UrlGeneratorInterface;

/**
 * Public endpoints of the authorization server: metadata (RFC 8414),
 * JWKS, dynamic client registration (RFC 7591), token, revocation (RFC 7009).
 */
final class ServerController
{
    public function __construct(
        private readonly Settings $settings,
        private readonly ServerFactory $factory,
        private readonly ClientRepository $clients,
        private readonly GrantRepository $grants,
        private readonly RedirectUriPolicy $redirectPolicy,
        private readonly Psr7Bridge $bridge,
        private readonly UrlGeneratorInterface $router,
        private readonly LoggerInterface $logger,
    ) {
    }

    public function metadataAction(): Response
    {
        if (!$this->settings->isConfigured()) {
            return $this->notConfigured();
        }
        $issuer = $this->settings->issuer();

        return $this->json([
            'issuer'                                => $issuer,
            'authorization_endpoint'                => $issuer.$this->path('kopexa_oauth_authorize'),
            'token_endpoint'                        => $issuer.$this->path('kopexa_oauth_token'),
            'registration_endpoint'                 => $issuer.$this->path('kopexa_oauth_register'),
            'revocation_endpoint'                   => $issuer.$this->path('kopexa_oauth_revoke'),
            'jwks_uri'                              => $issuer.$this->path('kopexa_oauth_jwks'),
            'scopes_supported'                      => array_keys($this->settings->scopes()),
            'response_types_supported'              => ['code'],
            'response_modes_supported'              => ['query'],
            'grant_types_supported'                 => ['authorization_code', 'refresh_token'],
            'token_endpoint_auth_methods_supported' => ['none'],
            'revocation_endpoint_auth_methods_supported' => ['none'],
            'code_challenge_methods_supported'      => ['S256'],
            'authorization_response_iss_parameter_supported' => false,
            'service_documentation'                 => 'https://github.com/kopexa-grc/mautic-stack/tree/main/image/extensions/mautic-oauth-bundle',
        ], 200, ['Cache-Control' => 'public, max-age=300']);
    }

    public function jwksAction(): Response
    {
        if (!$this->settings->isConfigured()) {
            return $this->notConfigured();
        }

        return $this->json(['keys' => [$this->settings->publicJwk()]], 200, ['Cache-Control' => 'public, max-age=300']);
    }

    public function registerAction(Request $request): Response
    {
        if (!$this->settings->isConfigured()) {
            return $this->notConfigured();
        }
        $data = json_decode($request->getContent(), true);
        if (!is_array($data)) {
            return $this->registrationError('invalid_client_metadata', 'Request body must be a JSON object.');
        }

        $redirectUris = $data['redirect_uris'] ?? null;
        if (!is_array($redirectUris) || [] === $redirectUris || count($redirectUris) > 10) {
            return $this->registrationError('invalid_redirect_uri', 'redirect_uris must list 1 to 10 URIs.');
        }
        foreach ($redirectUris as $uri) {
            if (!is_string($uri) || !$this->redirectPolicy->isAllowed($uri)) {
                return $this->registrationError('invalid_redirect_uri', sprintf('Redirect URI not allowed: %s', is_string($uri) ? $uri : gettype($uri)));
            }
        }
        foreach ((array) ($data['grant_types'] ?? []) as $grant) {
            if (!in_array($grant, ['authorization_code', 'refresh_token'], true)) {
                return $this->registrationError('invalid_client_metadata', sprintf('Unsupported grant type: %s', (string) $grant));
            }
        }
        foreach ((array) ($data['response_types'] ?? []) as $type) {
            if ('code' !== $type) {
                return $this->registrationError('invalid_client_metadata', sprintf('Unsupported response type: %s', (string) $type));
            }
        }

        $this->clients->purgeUnused();
        $name   = is_string($data['client_name'] ?? null) && '' !== trim($data['client_name']) ? trim($data['client_name']) : 'MCP client';
        $client = $this->clients->register($name, array_values($redirectUris));
        $this->logger->info('kopexa_oauth: registered client', ['client_id' => $client->getIdentifier(), 'name' => $name]);

        // Public client: secrets would add nothing for a client that cannot
        // keep them, PKCE protects the code instead. Whatever auth method was
        // requested, the server assigns "none" (RFC 7591 section 3.2.1).
        return $this->json([
            'client_id'                  => $client->getIdentifier(),
            'client_id_issued_at'        => time(),
            'client_name'                => $name,
            'redirect_uris'              => array_values($redirectUris),
            'grant_types'                => ['authorization_code', 'refresh_token'],
            'response_types'             => ['code'],
            'token_endpoint_auth_method' => 'none',
            'scope'                      => implode(' ', array_keys($this->settings->scopes())),
        ], 201, ['Cache-Control' => 'no-store']);
    }

    public function tokenAction(Request $request): Response
    {
        if (!$this->settings->isConfigured()) {
            return $this->notConfigured();
        }
        $resource = $request->request->get('resource');
        if (null !== $resource && rtrim((string) $resource, '/') !== $this->settings->resource()) {
            return $this->json(['error' => 'invalid_target', 'error_description' => 'Unknown resource.'], 400, ['Cache-Control' => 'no-store']);
        }

        try {
            $response = $this->factory->server()->respondToAccessTokenRequest($this->bridge->toPsr($request), $this->bridge->newResponse());
            if (is_string($clientId = $request->request->get('client_id'))) {
                $this->clients->touch($clientId);
            }
            if (1 === random_int(1, 50)) {
                $this->grants->purgeExpired();
            }
        } catch (OAuthServerException $e) {
            $response = $e->generateHttpResponse($this->bridge->newResponse());
        } catch (\Throwable $e) {
            $this->logger->error('kopexa_oauth: token endpoint failed', ['exception' => $e]);
            $response = OAuthServerException::serverError('Token request failed.')->generateHttpResponse($this->bridge->newResponse());
        }

        return $this->cors($this->bridge->toSymfony($response));
    }

    /**
     * RFC 7009. Access tokens are short-lived stateless JWTs and expire on
     * their own; refresh tokens are revoked together with all other grants
     * the user gave this client.
     */
    public function revokeAction(Request $request): Response
    {
        if (!$this->settings->isConfigured()) {
            return $this->notConfigured();
        }
        $token    = (string) $request->request->get('token', '');
        $clientId = (string) $request->request->get('client_id', '');
        if ('' === $token) {
            return $this->json(['error' => 'invalid_request', 'error_description' => 'token is required.'], 400);
        }

        try {
            $payload = json_decode(Crypto::decryptWithPassword($token, $this->settings->encryptionKey()), true);
            if (is_array($payload) && isset($payload['refresh_token_id'], $payload['client_id'])
                && ('' === $clientId || hash_equals((string) $payload['client_id'], $clientId))) {
                $this->grants->revokeRefreshToken((string) $payload['refresh_token_id']);
                if (isset($payload['user_id'])) {
                    $this->grants->revokeAllForClientAndUser((string) $payload['client_id'], (string) $payload['user_id']);
                }
            }
        } catch (\Throwable) {
            // Not a refresh token of ours (or an access token): nothing to do.
        }

        // Per RFC 7009 the response is 200 whether or not the token was known.
        return $this->cors(new Response('', 200, ['Cache-Control' => 'no-store']));
    }

    private function path(string $route): string
    {
        return $this->router->generate($route, [], UrlGeneratorInterface::ABSOLUTE_PATH);
    }

    private function notConfigured(): Response
    {
        return $this->json(['error' => 'temporarily_unavailable', 'error_description' => 'OAuth is not configured on this instance.'], 503);
    }

    private function registrationError(string $error, string $description): Response
    {
        return $this->json(['error' => $error, 'error_description' => $description], 400);
    }

    /**
     * @param array<string, mixed>  $data
     * @param array<string, string> $headers
     */
    private function json(array $data, int $status, array $headers = []): Response
    {
        $response = new JsonResponse($data, $status, $headers);
        $response->setEncodingOptions(JSON_UNESCAPED_SLASHES);

        return $this->cors($response);
    }

    /** Browser-based clients (MCP inspectors) call these endpoints cross-origin; no cookies are involved. */
    private function cors(Response $response): Response
    {
        $response->headers->set('Access-Control-Allow-Origin', '*');
        $response->headers->set('Access-Control-Allow-Headers', 'Authorization, Content-Type, MCP-Protocol-Version');

        return $response;
    }
}
