<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Controller;

use League\OAuth2\Server\Exception\OAuthServerException;
use League\OAuth2\Server\RequestTypes\AuthorizationRequestInterface;
use Mautic\CoreBundle\Helper\UserHelper;
use Mautic\CoreBundle\Model\AuditLogModel;
use MauticPlugin\KopexaOAuthBundle\Entity\User;
use MauticPlugin\KopexaOAuthBundle\Service\Psr7Bridge;
use MauticPlugin\KopexaOAuthBundle\Service\ServerFactory;
use MauticPlugin\KopexaOAuthBundle\Service\Settings;
use Symfony\Component\HttpFoundation\RedirectResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Security\Csrf\CsrfToken;
use Symfony\Component\Security\Csrf\CsrfTokenManagerInterface;

/**
 * Authorization endpoint. It lives under /s/, so Mautic's own login
 * (password or SAML SSO) authenticates the user before consent is shown.
 */
final class AuthorizeController
{
    private const SESSION_KEY = 'kopexa_oauth.pending';
    private const CSRF_ID     = 'kopexa_oauth_consent';

    public function __construct(
        private readonly Settings $settings,
        private readonly ServerFactory $factory,
        private readonly Psr7Bridge $bridge,
        private readonly UserHelper $userHelper,
        private readonly CsrfTokenManagerInterface $csrf,
        private readonly AuditLogModel $auditLog,
    ) {
    }

    public function authorizeAction(Request $request): Response
    {
        if (!$this->settings->isConfigured()) {
            return new Response('OAuth is not configured on this instance.', 503, ['Content-Type' => 'text/plain']);
        }
        $user = $this->userHelper->getUser();
        if (null === $user || !$user->getId()) {
            return new Response('Not logged in.', 401, ['Content-Type' => 'text/plain']);
        }

        if ($request->isMethod('POST')) {
            return $this->decide($request, (string) $user->getId());
        }

        $query = $request->query->all();
        try {
            $authRequest = $this->validate($request, $query);
        } catch (OAuthServerException $e) {
            return $this->errorResponse($e);
        }

        $txn                    = bin2hex(random_bytes(16));
        $pending                = $request->getSession()->get(self::SESSION_KEY, []);
        $pending                = array_slice(is_array($pending) ? $pending : [], -4, null, true);
        $pending[$txn]          = ['query' => $query, 'at' => time()];
        $request->getSession()->set(self::SESSION_KEY, $pending);

        return $this->consentPage($authRequest, $txn, $user->getName(), $user->getEmail());
    }

    private function decide(Request $request, string $userId): Response
    {
        if (!$this->csrf->isTokenValid(new CsrfToken(self::CSRF_ID, (string) $request->request->get('_token')))) {
            return new Response('Invalid CSRF token.', 400, ['Content-Type' => 'text/plain']);
        }
        $txn     = (string) $request->request->get('txn');
        $pending = $request->getSession()->get(self::SESSION_KEY, []);
        $entry   = is_array($pending) ? ($pending[$txn] ?? null) : null;
        if (!is_array($entry) || $entry['at'] < time() - 600) {
            return new Response('Authorization request expired. Start again from your client.', 400, ['Content-Type' => 'text/plain']);
        }
        unset($pending[$txn]);
        $request->getSession()->set(self::SESSION_KEY, $pending);

        try {
            $authRequest = $this->validate($request, $entry['query']);
            $approved    = 'approve' === $request->request->get('decision');
            $authRequest->setUser(new User($userId));
            $authRequest->setAuthorizationApproved($approved);

            $this->auditLog->writeToLog([
                'bundle'    => 'kopexa_oauth',
                'object'    => 'client',
                'objectId'  => 0,
                'action'    => $approved ? 'authorize' : 'deny',
                'details'   => [
                    'client_id'   => $authRequest->getClient()->getIdentifier(),
                    'client_name' => $authRequest->getClient()->getName(),
                    'scopes'      => array_map(fn ($s) => $s->getIdentifier(), $authRequest->getScopes()),
                ],
                'ipAddress' => $request->getClientIp(),
            ]);

            $response = $this->factory->server()->completeAuthorizationRequest($authRequest, $this->bridge->newResponse());
        } catch (OAuthServerException $e) {
            return $this->errorResponse($e);
        }

        return $this->bridge->toSymfony($response);
    }

    /**
     * Run league's validation plus the OAuth 2.1 / MCP specific rules:
     * PKCE with S256 only (no "plain", no missing method) and an RFC 8707
     * resource indicator that names this server's MCP endpoint.
     *
     * @param array<string, mixed> $query
     */
    private function validate(Request $request, array $query): AuthorizationRequestInterface
    {
        $authRequest = $this->factory->server()->validateAuthorizationRequest($this->bridge->toPsr($request, $query)->withMethod('GET'));

        $redirect = $authRequest->getRedirectUri() ?? $authRequest->getClient()->getRedirectUri()[0] ?? null;
        if (null !== $redirect && null !== $authRequest->getState()) {
            $redirect .= (str_contains($redirect, '?') ? '&' : '?').http_build_query(['state' => $authRequest->getState()]);
        }

        if ('S256' !== ($query['code_challenge_method'] ?? null)) {
            throw new OAuthServerException('PKCE with code_challenge_method=S256 is required.', 3, 'invalid_request', 400, 'code_challenge_method must be S256', $redirect);
        }
        if (isset($query['resource']) && rtrim((string) $query['resource'], '/') !== $this->settings->resource()) {
            throw new OAuthServerException('The requested resource is not served by this authorization server.', 3, 'invalid_target', 400, null, $redirect);
        }

        return $authRequest;
    }

    private function errorResponse(OAuthServerException $e): Response
    {
        // Only redirect back if league validated the redirect URI.
        if ($e->hasRedirect()) {
            return $this->bridge->toSymfony($e->generateHttpResponse($this->bridge->newResponse()));
        }

        return new Response(
            sprintf("Authorization request rejected: %s\n%s\n", $e->getErrorType(), $e->getHint() ?? $e->getMessage()),
            $e->getHttpStatusCode(),
            ['Content-Type' => 'text/plain; charset=utf-8']
        );
    }

    private function consentPage(AuthorizationRequestInterface $authRequest, string $txn, string $userName, string $email): Response
    {
        $e        = static fn (string $v): string => htmlspecialchars($v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        $scopes   = $this->settings->scopes();
        $redirect = (string) ($authRequest->getRedirectUri() ?? $authRequest->getClient()->getRedirectUri()[0] ?? '');
        $host     = (string) parse_url($redirect, PHP_URL_HOST);
        $items    = '';
        foreach ($authRequest->getScopes() as $scope) {
            $id = $scope->getIdentifier();
            $items .= sprintf('<li><code>%s</code> %s</li>', $e($id), $e($scopes[$id] ?? ''));
        }
        $token = $this->csrf->getToken(self::CSRF_ID)->getValue();

        $html = <<<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Authorize {$e($authRequest->getClient()->getName())}</title>
<style>
body{margin:0;font:16px/1.5 system-ui,sans-serif;background:#f4f6f8;color:#10253d}
main{max-width:30rem;margin:4rem auto;padding:2rem;background:#fff;border-radius:14px;box-shadow:0 1px 3px rgba(0,0,0,.12)}
h1{font-size:1.3rem;margin:0 0 1rem} code{background:#eef2f6;padding:0 .3em;border-radius:4px}
ul{padding-left:1.2rem} .muted{color:#5b6b7d;font-size:.9rem}
.actions{display:flex;gap:.75rem;margin-top:1.5rem}
button{flex:1;padding:.7rem;border-radius:8px;border:1px solid #006cb8;font:inherit;cursor:pointer}
.approve{background:#006cb8;color:#fff} .deny{background:#fff;color:#006cb8}
</style></head><body><main>
<h1><strong>{$e($authRequest->getClient()->getName())}</strong> wants to access Mautic</h1>
<p>Signed in as <strong>{$e($userName)}</strong> ({$e($email)}). The application acts with your Mautic permissions and may:</p>
<ul>{$items}</ul>
<p class="muted">After approval you are sent back to <strong>{$e($host)}</strong>. You can revoke access by disconnecting the application in its settings.</p>
<form method="post">
<input type="hidden" name="_token" value="{$e($token)}"><input type="hidden" name="txn" value="{$e($txn)}">
<div class="actions"><button class="deny" name="decision" value="deny">Deny</button><button class="approve" name="decision" value="approve">Allow</button></div>
</form></main></body></html>
HTML;

        return new Response($html, 200, [
            'Content-Type'            => 'text/html; charset=utf-8',
            'Cache-Control'           => 'no-store',
            'X-Frame-Options'         => 'DENY',
            'Content-Security-Policy' => "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https: http://localhost:* http://127.0.0.1:*; frame-ancestors 'none'; base-uri 'none'",
        ]);
    }
}
