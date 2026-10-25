#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Time::HiRes qw(time);
use Data::Shared qw(shared_get shared_compile sharedc_get);

my $root = Data::Shared->new;
my $h = eval { $root->mount('cache', 'hashmap:ii', undef, 100_000) };
die "hashmap backend unavailable: $@" unless $h;
my $native = $root->handle('/cache');
$native->put($_, $_ * 10) for 1 .. 1000;

my $cp = shared_compile('/cache/500');
for my $name (qw(string compiled)) {
    my $v = $name eq 'string' ? shared_get($root, '/cache/500') : sharedc_get($root, $cp);
    print "$name: /cache/500 = $v\n";
    die "mismatch" unless $v == 5000;
}

my $n = 50_000;
my $start = time();
shared_get($root, '/cache/500') for 1 .. $n;
printf "string   %d gets in %.2fs\n", $n, time() - $start;
$start = time();
sharedc_get($root, $cp) for 1 .. $n;
printf "compiled %d gets in %.2fs (see bench/ for stable numbers)\n", $n, time() - $start;
print "native handle is also available via \$root->handle('/cache')\n";
