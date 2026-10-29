use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use Data::Shared ();

# What the facade does to the process around it. Both of these need no backend:
# reading a manifest is pure Perl, and the lock refusal happens before the
# factory can return a handle.

# Reading the manifest localized $/ but not $., and $. carries perl's notion of
# the last read handle. A host looping over `while (<>) { close ARGV if eof }`
# therefore saw bare eof go true while its own input still had records, closed
# it, and silently processed only the first one.
subtest 'a manifest read leaves the host its own input handle' => sub {
    my $dir = tempdir(CLEANUP => 1);
    Data::Shared->new($dir);            # publish, so the next open reads it
    my ($fh, $file) = tempfile(UNLINK => 1);
    print {$fh} "first\nsecond\nthird\n" or die $!;
    close $fh or die $!;

    open my $in, '<', $file or die $!;
    my $line = <$in>;
    is $line, "first\n", 'the host read its first record';
    is $., 1, 'and $. counts it';
    ok !eof($in), 'its input is not at end';

    Data::Shared->new($dir);            # the call under test

    ok !eof, 'bare eof still reports the host handle, not the manifest';
    is $., 1, 'and $. still belongs to the host handle';
    my @rest = <$in>;
    is scalar @rest, 2, 'the remaining records are still readable';
    close $in;
};

# flock does not nest across descriptors, so a factory or a $SIG{__DIE__}
# observer that opened the same store waited for a lock only its own caller
# could release: an unbounded hang, with no process able to make progress.
subtest 'reopening a locked root from inside a factory is refused, not hung' => sub {
    my $dir = tempdir(CLEANUP => 1);
    Data::Shared->new($dir);
    my $root = Data::Shared->open($dir);

    my $entered = 0;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "hung: the lock was never refused\n" };
        alarm 10;
        $root->mount('f', sub { $entered++; Data::Shared->open($dir) });
        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;
    ok $entered, 'the factory ran';
    ok !$ok, 'the mount did not succeed';
    like $err, qr/already holds the manifest lock/,
        'the reopen is refused by name rather than blocking';
    unlike $err, qr/^hung:/, 'and it did not have to be timed out';

    ok eval { Data::Shared->open($dir); 1 },
        'the lock is released, so the store opens afterwards' or diag $@;
    is_deeply [$root->mounts], [], 'the cancelled mount left no record';
};

# A shared holder cannot block another shared holder, so that nesting stays
# legal: open() inside a read of the same store must keep working.
subtest 'a shared holder may still open the same root' => sub {
    my $dir = tempdir(CLEANUP => 1);
    Data::Shared->new($dir);
    my $inner;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "hung\n" };
        alarm 10;
        $inner = Data::Shared::Manifest::with_lock(
            Data::Shared->open($dir), 0, sub { Data::Shared->open($dir) });
        alarm 0;
        1;
    };
    alarm 0;
    ok $ok, 'a shared lock nested in a shared lock is allowed' or diag $@;
    ok $inner, 'and returns a usable root';
};

done_testing;
