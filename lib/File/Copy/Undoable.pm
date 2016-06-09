package File::Copy::Undoable;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

use IPC::System::Options 'system', -log=>1;
use File::MoreUtil qw(file_exists);
use File::Trash::Undoable;
#use PerlX::Maybe;
use Proc::ChildError qw(explain_child_error);

our %SPEC;

$SPEC{cp} = {
    v           => 1.1,
    summary     => 'Copy file/directory using rsync, with undo support',
    description => <<'_',

On do, will copy `source` to `target` (which must not exist beforehand). On
undo, will trash `target`.

Fixed state: `source` exists and `target` exists. Content or sizes are not
checked; only existence.

Fixable state: `source` exists and `target` doesn't exist.

Unfixable state: `source` does not exist.

_
    args        => {
        source => {
            schema => 'str*',
            req    => 1,
            pos    => 0,
        },
        target => {
            schema => 'str*',
            summary => 'Target location',
            description => <<'_',

Note that to avoid ambiguity, you must specify full location instead of just
directory name. For example: cp(source=>'/dir', target=>'/a') will copy /dir to
/a and cp(source=>'/dir', target=>'/a/dir') will copy /dir to /a/dir.

_
            req    => 1,
            pos    => 1,
        },
        target_owner => {
            schema => 'str*',
            summary => 'Set ownership of target',
            description => <<'_',

If set, will do a `chmod -Rh` on the target after rsync to set ownership. This
usually requires super-user privileges. An example of this is copying files on
behalf of user from a source that is inaccessible by the user (e.g. a system
backup location). Or, setting up user's home directory when creating a user.

Will do nothing if not running as super-user.

_
        },
        target_group => {
            schema => 'str*',
            summary => 'Set group of target',
            description => <<'_',

See `target_owner`.

_
        },
        rsync_opts => {
            schema => [array => {of=>'str*', default=>['-a']}],
            summary => 'Rsync options',
            description => <<'_',

By default, `-a` is used. You can add, for example, `--delete` or other rsync
options.

_
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
    deps => {
        prog => 'rsync',
    },
};
sub cp {
    my %args = @_;

    # TMP, schema
    my $tx_action  = $args{-tx_action} // '';
    my $dry_run    = $args{-dry_run};
    my $source     = $args{source};
    defined($source) or return [400, "Please specify source"];
    my $target     = $args{target};
    defined($target) or return [400, "Please specify target"];
    my $rsync_opts = $args{rsync_opts} // ['-a'];
    $rsync_opts = [$rsync_opts] unless ref($rsync_opts) eq 'ARRAY';

    if ($tx_action eq 'check_state') {
        return [412, "Source $source does not exist"]
            unless file_exists($source);
        my $te = file_exists($target);
        unless ($args{-tx_recovery} || $args{-tx_rollback}) {
            # in rollback/recovery, we might need to continue interrupted
            # transfer, so we allow target to exist
            return [304, "Target $target already exists"] if $te;
        }
        $log->info("(DRY) ".
                       ($te ? "Syncing" : "Copying")." $source -> $target ...")
            if $dry_run;
        return [200, "$source needs to be ".($te ? "synced":"copied").
                    " to $target", undef, {undo_actions=>[
                        ["File::Trash::Undoable::trash" => {path=>$target}],
                    ]}];

    } elsif ($tx_action eq 'fix_state') {
        my @cmd = ("rsync", @$rsync_opts, "$source/", "$target/");
        $log->info("Rsync-ing $source -> $target ...");
        system @cmd;
        return [500, "Can't rsync: ".explain_child_error($?)] if $?;
        if (defined($args{target_owner}) || defined($args{target_group})) {
            if ($> == 0) {
                $log->info("Chown-ing $target ...");
                @cmd = (
                    "chown", "-Rh",
                    join("", $args{target_owner}//"", ":",
                         $args{target_group}//""),
                    $target);
                system @cmd;
                return [500, "Can't chown: ".explain_child_error($?)] if $?;
            } else {
                $log->debug("Not running as root, not doing chown");
            }
        }
        return [200, "OK"];
    }
    [400, "Invalid -tx_action"];
}

1;
# ABSTRACT:

=head1 FAQ

=head2 Why do you use rsync? Why not, say, File::Copy::Recursive?

With C<rsync>, we can continue interrupted transfer. We need this ability for
recovery. Also, C<rsync> can handle hardlinks and preservation of ownership,
something which L<File::Copy::Recursive> currently does not do. And, being
implemented in C, it might be faster when processing large files/trees.


=head1 SEE ALSO

L<Setup>

L<Rinci::Transaction>

=cut
