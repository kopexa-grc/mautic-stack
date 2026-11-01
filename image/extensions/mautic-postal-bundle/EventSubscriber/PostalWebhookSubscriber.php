<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaPostalBundle\EventSubscriber;

use Mautic\EmailBundle\EmailEvents;
use Mautic\EmailBundle\Event\TransportWebhookEvent;
use MauticPlugin\KopexaPostalBundle\Service\PostalEventProcessor;
use MauticPlugin\KopexaPostalBundle\Service\SignatureVerifier;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\HttpFoundation\JsonResponse;

/**
 * Handles Postal webhooks sent to Mautic's transport callback endpoint
 * (POST /mailer/callback). Requests without Postal's signature header are
 * left for other transports.
 */
final class PostalWebhookSubscriber implements EventSubscriberInterface
{
    public function __construct(
        private readonly SignatureVerifier $verifier,
        private readonly PostalEventProcessor $processor,
    ) {
    }

    public static function getSubscribedEvents(): array
    {
        return [EmailEvents::ON_TRANSPORT_WEBHOOK => ['onTransportWebhook', 0]];
    }

    public function onTransportWebhook(TransportWebhookEvent $event): void
    {
        $request   = $event->getRequest();
        $signature = $request->headers->get('X-Postal-Signature-256');
        if (null === $signature) {
            return;
        }

        if (!$this->verifier->isConfigured()) {
            $event->setResponse(new JsonResponse(['error' => 'Postal webhook verification is not configured'], 503));

            return;
        }

        $body = $request->getContent();
        if (!$this->verifier->verify($body, $signature, $request->headers->get('X-Postal-Signature-KID'))) {
            $event->setResponse(new JsonResponse(['error' => 'invalid signature'], 403));

            return;
        }

        $data = json_decode($body, true);
        if (!is_array($data) || !is_string($data['event'] ?? null)) {
            $event->setResponse(new JsonResponse(['error' => 'malformed payload'], 400));

            return;
        }

        $handled = $this->processor->process($data['event'], is_array($data['payload'] ?? null) ? $data['payload'] : []);
        $event->setResponse(new JsonResponse(['status' => 'ok', 'event' => $data['event'], 'handled' => $handled]));
    }
}
