#!/usr/local/bin/perl

=pod

=head1 NAME

ct - general-purpose wrapper for B<cleartool>

=head1 SUMMARY

Use the B<--help> option to see full documentation for the current
customizations. The same text is also available via
"perldoc ClearCase::Ct::Profile".

=head1 USAGE

   ct [--wrapper-flags] ccase-args ...
   Wrapper-flags:
      --usage		Show this message and exit
      --help		Show documentation of current customizations
      --verbose		Print the underlying command before running it
      --debug		Print debug output from wrapper program
      --quiet		Suppress unnecessary messages
      --nopro		Do not read any profile files
      --reread		Read profiles in recursive invocations

=head1 DESCRIPTION

This is a wrapper over the clearcase command-line tool cleartool.  If
no profile files are found, or if the C<--nopro> flag is used, it
becomes a no-op, simply exec-ing the underlying command. If profiles
are found, they are C<require>d (I<included>) before continuing.  This
allows anyone who knows Perl sufficiently to extend and/or modify the
behavior of clearcase commands, or to create entire new commands which
will appear as extensions to ClearCase. Two profiles are searched for:
first I<Profile.pm> on the standard @INC path, then I<~/.ct_profile.pl> if
it exists. I<Profile.pm> is for site policy and enhancements, while the
I<~/.ct_profile.pl> is an opportunity for the user to customize his/her
personal environment.

Typically such value-added code will examine $ARGV[0] (the command
name) and modify the remainder of @ARGV as desired.  But there are no
limits to what perl code can be placed in these files or to what it can
examine before doing whatever it does.  You can even write your own
meta-commands within the profile which never return to the wrapper.

When a profile is C<require>d, the special variable C<$_> is set to the
name of the command and C<@_> is a copy of @ARGV.

The usage messages for new/extended/modified commands can be
added to by assigning to the hash entry $HelpData{command}.

We make use of the Getopt::Long perl module to form an orthogonal
namespace of command-line flags; those beginning with the traditional
'-' are directed at the underlying clearcase command(s), while flags
beginning with '--' are interpreted by the wrapper code.

That's all there is to it, unless the pre-op code pushes something onto
the @PostOpEvalStack array.  If any code is placed in @PostOpEvalStack,
we fork before running the real cmd and 'eval' the post-op code after it
finishes. The post-op code, if any, will have access to the command's
return code in C<$Retcode>.

=head1 COPYRIGHT

Copyright (c) 1997,1998 David Boyce (dsb@world.std.com). All rights
reserved.  This perl program is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut

# Unfortunately, we need a newer version of Getopt::Long than is supplied
# with the clearcase Perl command (5.002 as of CC 3.2, 5.001 on NT!),
# and the new Getopt::Long needs 5.004. Among other things.
# NOTE: Getopt::Long 2.17+ is recommended because it loads faster.
require 5.004;

# Get more portable handling of chdir plus $PWD tracking, etc.
use autouse 'Cwd' => qw(chdir fastcwd);

# Define helper functions and global vars. Since nobody but us will
# ever use ClearCase::Ct (?), we export from it at will.
use ClearCase::Ct qw(:all);

# We use Getopt::Long to parse an orthogonal namespace of flags directed
# at this wrapper program itself. The --xyz flags are meant for this
# program, the -xyz flags are sent on to clearcase. However, we don't
# make use of the 'prefix' setting because it wasn't in core 5.004.
{
   use vars qw(
      $opt_usage
      $opt_help
      $Cmd_Help
      $opt_nopro
      $opt_quiet
      $opt_reread
      $opt_verbose
      $opt_debug
   );

   use Getopt::Long;
   ## In the interest of speed we employ some hackery to avoid calling
   ## GetOptions() unnecessarily, since it's ~500 lines slow.

   # Always pass unrecognized options along unless otherwise requested.
   Getopt::Long::config('pass_through', 'no_ignore_case');

   # The real cleartool doesn't handle argv[1] == -h so we take care of it.
   GetOptions("help", "usage") if $ARGV[0] =~ /-[hu]/;

   # These might conflict with real CC flags so disable abbrevs.
   # Note that we don't make use of 'prefix=--' because it wasn't in
   # core 5.004.
   # $Cmd_Help represents the "real" -h flag but we parse it here as a
   # special case. It's global because it short-circuits Profile.pm
   if (grep /--|-h/, @ARGV) {
      $Getopt::Long::autoabbrev = 0;
      GetOptions("nopro", "quiet", "reread", "verbose", "debug",
		  "h|he|hel|help" => \$Cmd_Help);
      $Getopt::Long::autoabbrev = 1;
   }
}

use strict;

$ENV{_CT_DEBUG} = 1 if $opt_debug;
$opt_debug ||= $ENV{_CT_DEBUG};

# Print inlined documentation and exit if requested.
if ($opt_usage || ($ARGV[0] eq 'man' && $ARGV[1] eq $Wrapper)) {
   Exec('perldoc', $0);
} elsif ($opt_help || ($ARGV[0] eq 'man' && $ARGV[1] =~ /^profile(\.|\Z)/i)) {
   Exec('perldoc', 'ClearCase::Ct::Profile');
}

# We keep a 'recursion stack' in the env in order to detect when
# the wrapper is being forked recursively (i.e. is a child of itself).
# Special-case: start over again within a setview.
my $Recursing = 0;
if ($ARGV[0] eq 'setview') {
   delete $ENV{_CT_RECURSION};
} elsif ($ENV{_CT_RECURSION} && ! $opt_reread) {
   $ENV{_CT_RECURSION} .= ":$ARGV[0]";
   $Recursing = 1;
} else {
   $ENV{_CT_RECURSION} = "$ARGV[0]";
}

# We use this wrapper over require in order to implement
# the convenience features of setting $_ to the command name
# and @_ to the current @ARGV within the required files.
# Also sets up the hash %Argv as a reverse lookup into @ARGV for
# ease in checking whether an option was passed.
sub Require
{
   my $profile = shift;
   # Set up the reverse hash pointing back into @ARGV;
   local %main::Argv = ();
   for my $i (0..$#ARGV) { $main::Argv{$ARGV[$i]} = $i }
   local($_) = $_[0];
   # Use eval so syntax errors etc won't cause disastrous failures.
   eval {
      Dbg("require: $profile ($ARGV[0], @ARGV[1..$#ARGV])");
      require $profile;
   }
}

# Special case for help messages: if the user passed -h or invoked
# the 'help' command, we dump the available help data into a
# hash before processing any profiles. Then after reading the
# profiles we print the appropriate key(s) from the hash. This
# allows real commands to have help data modified/appended and
# also lets pseudo-commands create their own usage msgs by assigning
# a string to $HelpData{pseudo-cmd}.
my($_help_cmd, %_help_keys);
use vars qw(%HelpData);
if ($Cmd_Help || $ARGV[0] eq 'help') {
   $_help_cmd = $Cmd_Help ? $ARGV[0] : $ARGV[1] || $ARGV[0];
   my $key;
   for (`cleartool help`) {
      $key = $1 if /^Usage:\s+(\S+)/;
      $HelpData{$key} .= $_;
   }
   chomp %HelpData;

   # Map unique abbreviations to real names, e.g. lsvt->lsvtree,
   # since "cleartool lsvt -h" is supported.
   for (keys %HelpData) {
      for my $i (2..length) {
	 my $sub = substr($_, 0, $i);
	 if ($_help_keys{$sub}) {
	    $_help_keys{$sub} = '_null_';
	 } else {
	    $_help_keys{$sub} = $_;
	 }
      }
   }

   # Also, there are a few special-case abbreviations:
   $_help_keys{mv} = $_help_keys{move};
   $_help_keys{co} = $_help_keys{checkout};
   $_help_keys{unco} = $_help_keys{uncheckout};
   $_help_keys{ci} = $_help_keys{checkin};
   $_help_keys{lsco} = $_help_keys{lscheckout};
   $_help_keys{lsp} = $_help_keys{lsprivate};
}

#############################################################################
# Profile processing.
#############################################################################

if (! $opt_nopro && ! $Recursing) {
   # Read the global profile.
   Require('ClearCase/Ct/Profile.pm', @ARGV);
   ($@ =~ /t locate|return a true value/) ? warn "$@" : die "$@" if $@;

   # Ignore the personal profile if running setuid or su-ed.
   if (-r "$ENV{HOME}/.ct_profile.pl" && ! $Setuid) {
      Require("$ENV{HOME}/.ct_profile.pl", @ARGV);
      warn "$@" if $@ && ($@ !~ /t locate|return a true value/);
   }
}

#############################################################################
# Execute the underlying (wrapped) command.
#############################################################################

# Second half of help-msg processing.  See above.
if (defined $_help_cmd) {
   if ($_help_cmd eq 'help') {
       for (keys %HelpData) { print "$HelpData{$_}\n" }
   } elsif ($HelpData{$_help_cmd}) {
      print $HelpData{$_help_cmd}, "\n";
   } elsif ($_help_keys{$_help_cmd} !~ /^$|_null_/) {
      print $HelpData{$_help_keys{$_help_cmd}}, "\n";
   } else {
      Die("Unrecognized command: \"$_help_cmd\"\n");
   }
   exit 0;
}

# Optional verbosity.
warn "+ $Wrapper @ARGV\n" if $opt_verbose && !$opt_quiet;

# Now exec the real cmd and we're done, unless a post-op eval stack exists.
# Also exec if running setuid since we won't be running any post-ops anyway.
if (@::PostOpEvalStack && ! $Setuid) {
   $::Retcode = System($ClearCmd, @ARGV);
} else {
   if ($Setuid) {
      # Security considerations before exec-ing in setuid mode.
      $ENV{PATH} = '/usr/bin';
      $ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
      delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
   }
   Exec($ClearCmd, @ARGV);
}

#############################################################################
# Post-op processing
#############################################################################

# Caught a signal - skip post-op code.
exit $::Retcode if ($::Retcode & 0xff);

# Execute any post-op eval code nuggets.
for (@::PostOpEvalStack) {
   Dbg("EVAL $_");
   eval || ( chomp $@, Die "$Wrapper: $@" );
}

# The return code of the real command.
exit $::Retcode >> 8;
