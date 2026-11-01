<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaPostalBundle\Service;

use Mautic\EmailBundle\Model\TransportCallback;
use Mautic\LeadBundle\Entity\DoNotContact;
use Psr\Log\LoggerInterface;

/**
 * Maps Postal webhook events onto Mautic's TransportCallback API, the same
 * mechanism Mautic's transport integrations use to record failures.
 *
 * - MessageBounced                   -> DNC "bounced"
 * - MessageDeliveryFailed (HardFail) -> DNC "bounced"
 * - everything else (Sent, Delayed, Held, Loaded, LinkClicked, ...) is ignored
 */
class PostalEventProcessor
{
    public function __construct(
        private readonly TransportCallback $transportCallback,
        private readonly LoggerInterface $logger,
    ) {
    }

    /**
     * @param array<string, mixed> $payload
     *
     * @return bool whether the event resulted in a Mautic update
     */
    public function process(string $event, array $payload): bool
    {
        [$message, $comment] = match ($event) {
            'MessageBounced'        => [$payload['original_message'] ?? [], 'Postal: bounce received'],
            'MessageDeliveryFailed' => ($payload['status'] ?? 'HardFail') === 'HardFail'
                ? [$payload['message'] ?? [], 'Postal: delivery failed — '.trim((string) ($payload['details'] ?? ''))]
                : [[], ''],
            default => [[], ''],
        };

        if (!is_array($message) || [] === $message) {
            return false;
        }
        if (($message['direction'] ?? 'outgoing') !== 'outgoing') {
            return false;
        }

        $address = trim((string) ($message['to'] ?? ''));
        if (false === filter_var($address, FILTER_VALIDATE_EMAIL)) {
            $this->logger->warning('Postal: webhook without a valid recipient', ['event' => $event]);

            return false;
        }

        $this->transportCallback->addFailureByAddress($address, mb_substr($comment, 0, 255), DoNotContact::BOUNCED);
        $this->logger->info('Postal: marked contact as bounced', ['event' => $event, 'message_id' => $message['id'] ?? null]);

        return true;
    }
}
