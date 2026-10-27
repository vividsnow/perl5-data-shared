use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use Fcntl ();
use Data::Shared;

# The data files are owner-only, so the directory and the lock that guards every
# topology mutation must not be looser: a group-writable root lets another user
# unlink the manifest, and a group-writable lock lets them hold it shut.
my $parent = tempdir(CLEANUP => 1);
my $dir    = "$parent/root";

my $umask = umask 0;            # worst case: nothing masked off
my $root  = Data::Shared->new($dir);
my $mounted = eval { $root->mount('cache', 'hashmap:ii', undef, 64); 1 };
my $err = $@;
umask $umask;
plan skip_all => "backend unavailable: $err" unless $mounted;

sub mode_of {
    my ($path) = @_;
    my @st = stat $path or return undef;
    return $st[2] & 07777;
}

# A path that does not exist used to satisfy every check here: mode_of returns
# undef and `undef & 077` is 0, so absence read as owner-only -- on the one
# assertion in this file that is about security.
sub is_owner_only {
    my ($path, $label) = @_;
    my $mode = mode_of($path);
    ok defined $mode, "$label exists" or return;
    is $mode & 077, 0, "$label is owner-only"
        or diag sprintf('%s mode is %04o', $label, $mode);
}

is_owner_only($dir, 'root directory');
is_owner_only("$dir/.manifest.lock", 'manifest lock');
is_owner_only("$dir/manifest.json", 'manifest');

# The root must still work normally after the tightening.
Data::Shared::shared_set($root, '/cache/7', 42);
is Data::Shared::shared_get($root, '/cache/7'), 42, 'root still usable';

undef $root;
my $reopened = Data::Shared->open($dir);
is Data::Shared::shared_get($reopened, '/cache/7'), 42, 'reopen still works';

# The composite subtree was the only part of a store taking its mode from the
# ambient umask, so under umask 0 its directories and its lock -- the one that
# serialises every child create and delete -- were world-writable.
{
    my $cdir = "$parent/comp";
    my $mask = umask 0;
    # The root construction belongs inside the eval too, or a die there leaks
    # umask 0 into whatever is appended after this block.
    my $comp;
    my $ok = eval { $comp = Data::Shared->new($cdir);
                    $comp->mount('u', ['hashmap:ss', 64, ['hashmap:ss', 8]]);
                    Data::Shared::shared_set($comp, '/u/a/k', 1); 1 };
    my $why = $@;
    umask $mask;
    # Asserted, not assumed: wrapped in a bare "if" the five checks below
    # vanished silently and the file still passed, so a mode regression at the
    # site they guard was invisible. hashmap is this file's own skip_all probe,
    # so a failure here is a real failure.
    ok $ok, 'a composite mounts and writes under umask 0' or diag $why;
    if ($ok) {
        for my $path ('.children', '.children/u', '.children/u/.lock') {
            is_owner_only("$cdir/$path", "$path under umask 0");
        }
        # And a lock nobody can write must not make the store unopenable: a
        # section that only reads needs no write access to it. Where perl
        # emulates flock with fcntl, an exclusive lock on a read-only
        # descriptor cannot work at all, so probe before asserting it.
        undef $comp;
        my $ro_lock_works = do {
            my ($probe_fh, $probe) = File::Temp::tempfile(UNLINK => 1);
            close $probe_fh;
            open my $rfh, '<', $probe or die "probe: $!";
            my $ok = flock $rfh, Fcntl::LOCK_EX();
            flock $rfh, Fcntl::LOCK_UN() if $ok;
            $ok;
        };
        if ($ro_lock_works) {
            chmod 0444, "$cdir/.children/u/.lock";
            my $ro = eval { Data::Shared->open($cdir) };
            ok $ro, 'a store with a read-only composite lock still opens' or diag $@;
            is eval { Data::Shared::shared_get($ro, '/u/a/k') }, 1, 'and reads through it'
                if $ro;
            chmod 0600, "$cdir/.children/u/.lock";
        }
        else {
            # Not `ok 1`: a tautology counted the uncovered platform as a pass.
            note 'this perl cannot lock a read-only descriptor; that case is not covered here';
        }
    }
}

done_testing;
