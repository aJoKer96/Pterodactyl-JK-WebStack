<?php

declare(strict_types=1);

$secretFile = '/home/container/config/phpmyadmin.secret';
$secret = is_readable($secretFile) ? trim((string) file_get_contents($secretFile)) : '';

if (strlen($secret) !== 32) {
    throw new RuntimeException('phpMyAdmin secret is missing or not exactly 32 bytes.');
}

$cfg['blowfish_secret'] = $secret;

$i = 1;
$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = '3306';
$cfg['Servers'][$i]['connect_type'] = 'tcp';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;

$cfg['TempDir'] = '/home/container/tmp/phpmyadmin';
