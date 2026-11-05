<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOpsBundle\Service;

use Mautic\CategoryBundle\Entity\Category;
use Mautic\CategoryBundle\Model\CategoryModel;
use Mautic\CoreBundle\Configurator\Configurator;
use Mautic\CoreBundle\Helper\CoreParametersHelper;
use Mautic\CoreBundle\Helper\ThemeHelperInterface;
use Mautic\PageBundle\Entity\Page;
use Mautic\PageBundle\Model\PageModel;

/**
 * Brings the email preference center to the state declared in the Helm
 * values (mautic.preferenceCenter, passed as MAUTIC_PREFERENCE_CENTER JSON):
 *
 * - topics: global categories, matched by name; missing ones are created,
 *   descriptions follow the values; other categories are never touched;
 * - page: the preference page, matched by alias; created from the theme the
 *   way the builder renders it, marked as preference center and published.
 *   Its content is not overwritten afterwards (it may be edited in the
 *   builder) unless page.updateContent is set;
 * - settings: Mautic shows the preferences with the topics (not segments)
 *   on the unsubscribe link, the page is the default preference center,
 *   and system pages use the given theme. Written to config/local.php
 *   only when they differ.
 */
class PreferenceCenterSync
{
    private const KEYS      = ['topics', 'page', 'frequency', 'pauseDates', 'systemTheme'];
    private const PAGE_KEYS = ['title', 'alias', 'theme', 'language', 'updateContent'];

    public function __construct(
        private readonly CategoryModel $categories,
        private readonly PageModel $pages,
        private readonly ThemeHelperInterface $themes,
        private readonly Configurator $configurator,
        private readonly CoreParametersHelper $parameters,
    ) {
    }

    /**
     * @return array{topics: list<array{name: string, description: string}>, page: array{title: string, alias: string, theme: string, language: string, updateContent: bool}, frequency: bool, pauseDates: bool, systemTheme: string}
     *
     * @throws \InvalidArgumentException on any invalid value
     */
    public function parse(string $json): array
    {
        try {
            $data = json_decode($json, true, 32, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new \InvalidArgumentException('MAUTIC_PREFERENCE_CENTER is not valid JSON: '.$e->getMessage());
        }
        if (!is_array($data) || array_is_list($data)) {
            throw new \InvalidArgumentException('MAUTIC_PREFERENCE_CENTER must be a JSON object');
        }

        $errors = [];
        foreach (array_diff(array_keys($data), self::KEYS) as $key) {
            $errors[] = "unknown key \"$key\" (allowed: ".implode(', ', self::KEYS).')';
        }
        $topics = [];
        $names  = [];
        foreach ((array) ($data['topics'] ?? []) as $i => $topic) {
            $name = is_array($topic) && is_string($topic['name'] ?? null) ? trim($topic['name']) : '';
            if ('' === $name || mb_strlen($name) > 191) {
                $errors[] = sprintf('topic %d: "name" is required (at most 191 characters)', (int) $i + 1);
                continue;
            }
            if (isset($names[mb_strtolower($name)])) {
                $errors[] = "topic \"$name\": declared twice";
                continue;
            }
            $names[mb_strtolower($name)] = true;
            foreach (array_diff(array_keys($topic), ['name', 'description']) as $key) {
                $errors[] = "topic \"$name\": unknown key \"$key\" (allowed: name, description)";
            }
            $topics[] = ['name' => $name, 'description' => trim((string) ($topic['description'] ?? ''))];
        }
        if ([] === $topics) {
            $errors[] = 'at least one topic is required';
        }

        $page = is_array($data['page'] ?? null) ? $data['page'] : [];
        foreach (array_diff(array_keys($page), self::PAGE_KEYS) as $key) {
            $errors[] = "page: unknown key \"$key\" (allowed: ".implode(', ', self::PAGE_KEYS).')';
        }
        $page = [
            'title'         => trim((string) ($page['title'] ?? 'E-Mail-Einstellungen')),
            'alias'         => trim((string) ($page['alias'] ?? 'einstellungen')),
            'theme'         => trim((string) ($page['theme'] ?? 'kopexa-preferences')),
            'language'      => trim((string) ($page['language'] ?? 'de')),
            'updateContent' => true === ($page['updateContent'] ?? false),
        ];
        if (1 !== preg_match('/^[a-z0-9][a-z0-9-]*$/', $page['alias'])) {
            $errors[] = 'page.alias: lowercase letters, digits and hyphens only';
        }
        $systemTheme = trim((string) ($data['systemTheme'] ?? 'kopexa'));
        foreach (['page.theme' => $page['theme'], 'systemTheme' => $systemTheme] as $what => $theme) {
            if ('' !== $theme && !$this->themes->exists($theme)) {
                $errors[] = "$what: theme \"$theme\" is not installed";
            }
        }

        if ([] !== $errors) {
            throw new \InvalidArgumentException("invalid preference center:\n  - ".implode("\n  - ", $errors));
        }

        return [
            'topics'      => $topics,
            'page'        => $page,
            'frequency'   => true === ($data['frequency'] ?? false),
            'pauseDates'  => true === ($data['pauseDates'] ?? false),
            'systemTheme' => $systemTheme,
        ];
    }

    /**
     * @param array{topics: list<array{name: string, description: string}>, page: array{title: string, alias: string, theme: string, language: string, updateContent: bool}, frequency: bool, pauseDates: bool, systemTheme: string} $declared
     *
     * @return list<string> what was done, one line each
     */
    public function apply(array $declared, bool $dryRun = false): array
    {
        $log = [];
        foreach ($declared['topics'] as $topic) {
            $log[] = $this->syncTopic($topic, $dryRun);
        }
        [$pageId, $log[]] = $this->syncPage($declared['page'], $dryRun);
        $log[]            = $this->syncSettings($declared, $pageId, $dryRun);

        return $log;
    }

    /** @param array{name: string, description: string} $topic */
    private function syncTopic(array $topic, bool $dryRun): string
    {
        $category = $this->categories->getRepository()->findOneBy(['title' => $topic['name'], 'bundle' => 'global']);
        if ($category instanceof Category) {
            if ((string) $category->getDescription() === $topic['description']) {
                return sprintf('topic "%s": unchanged (id %d)', $topic['name'], $category->getId());
            }
            if (!$dryRun) {
                $category->setDescription($topic['description']);
                $this->categories->saveEntity($category);
            }

            return sprintf('topic "%s": description updated (id %d)', $topic['name'], $category->getId());
        }
        if ($dryRun) {
            return sprintf('topic "%s": created', $topic['name']);
        }
        $category = new Category();
        $category->setTitle($topic['name']);
        $category->setDescription($topic['description']);
        $category->setBundle('global');
        $category->setIsPublished(true);
        $this->categories->saveEntity($category);

        return sprintf('topic "%s": created (id %d)', $topic['name'], $category->getId());
    }

    /**
     * @param array{title: string, alias: string, theme: string, language: string, updateContent: bool} $declared
     *
     * @return array{0: int, 1: string}
     */
    private function syncPage(array $declared, bool $dryRun): array
    {
        $page  = $this->pages->getRepository()->findOneBy(['alias' => $declared['alias']]);
        $isNew = !$page instanceof Page;
        $page ??= new Page();

        $changed = [];
        if ($isNew) {
            $page->setTitle($declared['title']);
            $page->setAlias($declared['alias']);
            $page->setLanguage($declared['language']);
        }
        $themeChanged = !$isNew && $page->getTemplate() !== $declared['theme'];
        if ($isNew || $themeChanged) {
            $page->setTemplate($declared['theme']);
            $changed[] = 'theme';
        }
        if ($isNew || $themeChanged || $declared['updateContent']) {
            if (!$dryRun) {
                $page->setCustomHtml($this->render($page, $declared['theme']));
            }
            $changed[] = 'content';
        }
        if (!$page->getIsPreferenceCenter()) {
            $page->setIsPreferenceCenter(true);
            $changed[] = 'preference center';
        }
        if (!$page->isPublished()) {
            $page->setIsPublished(true);
            $changed[] = 'published';
        }

        if ([] === $changed) {
            return [(int) $page->getId(), sprintf('page "%s": unchanged (id %d)', $declared['alias'], $page->getId())];
        }
        if (!$dryRun) {
            $this->pages->saveEntity($page);
        }

        return [(int) $page->getId(), sprintf('page "%s": %s%s', $declared['alias'], $isNew ? 'created' : 'updated – '.implode(', ', $changed), $page->getId() ? ' (id '.$page->getId().')' : '')];
    }

    /** The theme's page template, rendered as the GrapesJS builder does when a page is created. */
    private function render(Page $page, string $theme): string
    {
        $html = $this->themes->renderThemeTemplate(
            $this->themes->checkForTwigTemplate('@themes/'.$theme.'/html/page.html.twig'),
            ['isNew' => true, 'content' => [], 'page' => $page, 'template' => $theme, 'basePath' => '']
        );

        // Editor-only stylesheets (the builder's own CSS) do not belong in the page.
        return (string) preg_replace('#<link\b[^>]*href="[^"]*GrapesJsBuilderBundle[^"]*"[^>]*>\s*#i', '', $html);
    }

    /** @param array{frequency: bool, pauseDates: bool, systemTheme: string} $declared */
    private function syncSettings(array $declared, int $pageId, bool $dryRun): string
    {
        $wanted = [
            'show_contact_preferences'        => true,
            'show_contact_categories'         => true,
            'show_contact_segments'           => false,
            'show_contact_preferred_channels' => false,
            'show_contact_frequency'          => $declared['frequency'],
            'show_contact_pause_dates'        => $declared['pauseDates'],
            'email_default_preference_center_id' => $pageId ?: null,
        ];
        if ('' !== $declared['systemTheme']) {
            $wanted['theme'] = $declared['systemTheme'];
        }

        $changed = [];
        foreach ($wanted as $key => $value) {
            $current = $this->parameters->get($key);
            if ('email_default_preference_center_id' === $key ? (int) $current !== (int) $value : $current !== $value) {
                $changed[$key] = $value;
            }
        }
        if ([] === $changed) {
            return 'settings: unchanged';
        }
        if (!$dryRun) {
            if (!$this->configurator->isFileWritable()) {
                throw new \RuntimeException('config/local.php is not writable');
            }
            $this->configurator->mergeParameters($changed);
            $this->configurator->write();
        }

        return 'settings: '.implode(', ', array_keys($changed));
    }
}
