package ClearCase::Ct;

=head1 NAME

ClearCase::Ct - general-purpose wrapper for cleartool program

=head1 SYNOPSIS

See also "perldoc ClearCase::Ct::Profile" and "perldoc `whence ct`".

ClearCase::Ct provides service functions and global constants to
the C<ct> wrapper program and the ClearCase::Ct::Profile module.

=head1 DESCRIPTION

Exported functions:

=cut

use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS);

require Exporter;

@ISA = qw(Exporter);
$VERSION = '1.01';

use strict;

# We could use this but it seems like a pretty heavyweight operation.
# use Config.pm;

# Hacks for portability with NT env vars.
$ENV{LOGNAME} ||= lc $ENV{USERNAME};
$ENV{HOME} ||= "$ENV{HOMEDRIVE}/$ENV{HOMEPATH}";

use vars qw($Win32 $Wrapper $CCHome $ClearCmd $DevNull
	    $Editor $TmpDir $Setuid);

@EXPORT_OK = qw(Dbg Die Warn Exec System Backtick Prompt
	        ReadOptions StripOptions RemainingOptions
	        $Win32 $Wrapper $CCHome $ClearCmd $DevNull
	        $Editor $TmpDir $Setuid);
%EXPORT_TAGS = ( 'all' => [@EXPORT_OK] );

# To avoid having to use an RE on $^O each time or use Config.
$Win32 = ($^O =~ /win32/i);

# In aid of Unix/NT portability.
$DevNull = $Win32 ? 'NUL' : '/dev/null';

# Unwind the default-editor priority stack.
$Editor = $ENV{WINEDITOR} || $ENV{VISUAL} || $ENV{EDITOR} ||
	    ($Win32 ? 'notepad' : 'vi');

# Figure out the best place to put temp files.
$TmpDir = $ENV{TMPDIR} || $ENV{TEMP} || $ENV{TMP} ||
	    ($Win32 ? '/winnt/temp' : '/tmp');

# Adjust $0 to make sure it represents a fully-qualified path.
$0 = join('/', $ENV{PWD} || ::fastcwd(), $0) if $0 !~ m%^[/\\]|^[a-z]:\\%i;

# Convert any backslashes in $0 to forward slashes for consistency.
$0 =~ s%\\%/%g if $Win32;

# Now determine the name we were run as.
($Wrapper) = reverse split '/', $0;

# Remember if we're in a setuid situation.
$Setuid = ($< != $>) unless $Win32;

# Make our best guess at where the clearcase executables are installed.
$CCHome = $ENV{ATRIAHOME} || ($Win32 ? 'C:/atria' : '/usr/atria');

# The 'ct' program can be installed as a *complete* wrapper by
# moving $ATRIAHOME/bin/cleartool to $ATRIAHOME/bin/wrapped/cleartool
# and copying 'ct' to $ATRIAHOME/bin/cleartool.
$ClearCmd = "$CCHome/bin/wrapped/cleartool"
    if -x "$CCHome/bin/wrapped/cleartool";

# We use $ClearCmd instead of 'cleartool' to allow for the
# possibility of extending this wrapper to other programs.
$ClearCmd ||= "$CCHome/bin/cleartool";

# This supports the ability to run, for example, "lsvtree" as a shortcut
# for "ct lsvtree" if there's a link by that name.
if ($Wrapper !~ /^ct$|cleartool/ && -f "$CCHome/doc/man/cat1/ct+$Wrapper.1") {
   unshift(@ARGV, $Wrapper);
   $0 = 'ct';
}

=over 4

=item * Dbg($string, $level)

Standard debugging routine. Takes two scalar args: a string to print,
plus an optional number of stack frames to go backwards before reporting
line number and file data.

=cut

# Standard debugging routine.
sub Dbg
{
   return unless defined $::opt_debug;
   my ($msg, $level) = @_;
   my($package, $fname, $line) = caller $level;
   my($fn) = reverse split '/', $fname;
   print STDERR "++ $fn:$line: [$ENV{_CT_RECURSION}] $msg\n";
}

=item * Die($string)

Die with a standard error msg format. Same behavior as die() otherwise.

=cut

sub Die { die "$Wrapper: Error: @_"; }

=item * Warn($string)

Warn with a standard error msg format. Same behavior as warn() otherwise.

=cut

sub Warn { warn "$Wrapper: Warning: @_"; }

=item * Exec(LIST)

A wrapper for exec() which handles printing of debug and exec-fail msgs.
Also works around a Win32/5.004 bug in exec().

=cut

sub Exec
{
   Dbg("exec: @_", 1);
   if ($Win32) {
      # Bug in NT exec(), behaves like fork/exec with no wait.
      system(@_);
      exit $?;
   } else {
      exec(@_);
      # if caller checks for return, respect that decision
      Die "$_[0]: $!" unless defined wantarray;
   }
}

=item * System(LIST)

A wrapper for system() which handles printing of debug msgs.
Also masks off all the meaningless bits.

=cut

sub System
{
   Dbg("system: @_", 1);
   return system(@_) & 0xffff;
}

=item * Backtick(LIST)

A replacement for `cmd` with no shell needed, as suggested in Camel5.
Also more secure in setuid usage. Made available here for use in
profiles.

=cut

sub Backtick
{
   Dbg("backtick: @_", 1);
   # No fork() on &^&#@$ Win32.
   if ($Win32) {
      return `@_`;
   } else {
      die unless defined(my $pid = open(CHILD, "-|"));
      if ($pid) {			#parent
	 my @output = <CHILD>;
	 close(CHILD);
	 return @output;
      } else {			# child
	 exec(@_) || die "$_[0]: $!";
      }
   }
}

=item * Prompt(LIST)

Run clearprompt with specified args and return results.  Temp file
creation/removal is handled here automatically.  NOTE: the -prompt
<string> argument must come last so we can quote it appropriately to
deal with the remarkably lame NT shell.

=cut

sub Prompt
{
   my @cmd = @_;
   my $tmpf = "$TmpDir/clearprompt.$$";
   my $cpt = join('/', $CCHome, 'bin', 'clearprompt');
   # Hack the quoting of the -prompt arg for NT.
   $cmd[-1] = "\"$cmd[-1]\"" if $Win32;
   push(@cmd, '-out', $tmpf);
   system($cpt, @cmd) && exit($?>>8);
   open(TMPF, $tmpf) || die "$tmpf: $!";
   local($/) = undef;
   my $response = <TMPF>;
   close(TMPF);
   unlink $tmpf;
   return $response;
}

=item * Option Parsing

This is a set of functions based on Getopt::Long::GetOptions():

=over 4

=item 1. ReadOptions(\@ARGV, LIST)

Works much like GetOptions but does not modify the referenced \@ARGV -
it's a lookahead option processor.

=cut

sub ReadOptions
{
   my $r_argv = shift;
   local(@ARGV) = @$r_argv;  # referenced implicitly by GetOptions()
   Getopt::Long::GetOptions(@_);
}

=item 2. StripOptions(\@ARGV, LIST)

Parse and strip the specified options from the referenced \@ARGV,
throwing away their values.

=cut

sub StripOptions
{
   my $r_argv = shift; # not used, here for consistency with the other funcs.
   my %null = ();
   Getopt::Long::GetOptions(\%null, @_);
}

=item 3. RemainingOptions(\@ARGV, LIST)

Like GetOptions but does not modify the current @ARGV; instead it returns
an array containing the subset of unparsed elements of ARGV.

=cut

sub RemainingOptions
{
   my $r_argv = shift;
   local(@ARGV) = @$r_argv;  # referenced implicitly by GetOptions()
   my %null = ();
   Getopt::Long::GetOptions(\%null, @_);
   return @ARGV;
}

=back

=cut

1;
