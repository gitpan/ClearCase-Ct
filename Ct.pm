package ClearCase::Ct;

=head1 NAME

ClearCase::Ct - general-purpose wrapper for cleartool program

=head1 SYNOPSIS

See also "perldoc ClearCase::Ct::Profile" and "perldoc `whence ct`".

ClearCase::Ct provides service functions and global constants to
the C<ct> wrapper program and the ClearCase::Ct::Profile module.

=head1 COPYRIGHT

Copyright (c) 1997,1998,1999 David Boyce (dsb@world.std.com). All rights
reserved.  This perl program is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=head1 DESCRIPTION

Exported functions:

=cut

use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS);

require Exporter;

@ISA = qw(Exporter);
$VERSION = '1.17';

use strict;

# Get more portable handling of chdir plus $PWD tracking, etc.
use autouse 'Cwd' => qw(chdir fastcwd);

# Similarly for filename parsing.
use autouse 'File::Basename' => qw(fileparse basename dirname);

# We could use this but it seems like a pretty heavyweight operation.
# use Config.pm;

# Hacks for portability with NT env vars.
$ENV{LOGNAME} ||= lc $ENV{USERNAME};
$ENV{HOME} ||= "$ENV{HOMEDRIVE}/$ENV{HOMEPATH}";

use vars qw($Win32 $Wrapper $CCHome $ClearCmd $DevNull
	    $Editor $TmpDir $Setuid %Vgra);

@EXPORT_OK = qw(Dbg Die Warn Exec System Qx Prompt DosGlob
	        ReadOptions StripOptions RemainingOptions
		SplitArgv
		chdir fastcwd fileparse basename dirname
	        $Win32 $Wrapper $CCHome $ClearCmd $DevNull
	        $Editor $TmpDir $Setuid %Vgra);
%EXPORT_TAGS = ( 'all' => [@EXPORT_OK] );

# To avoid having to use an RE on $^O each time or use Config.
$Win32 = ($^O =~ /win32/i);

# In aid of Unix/NT portability.
$DevNull = $Win32 ? 'NUL' : '/dev/null';

# Unwind the default-editor priority stack.
$Editor = $ENV{WINEDITOR} || $ENV{VISUAL} || $ENV{EDITOR} ||
	    ($Win32 ? 'notepad' : 'vi');

# Figure out the best place to put temp files.
$TmpDir = $Win32 ?
	    ($ENV{TEMP} || $ENV{TMP} || 'C:/winnt/temp') :
	    ($ENV{TMPDIR} || '/tmp');
# This depends on having such a program or script, which basically
# just re-execs 'xterm -e vi "$@"'.
$Editor = 'xvi' if !$Win32 && $ENV{ATRIA_FORCE_GUI} && $Editor =~ /\w*vi\w*$/;

# Adjust $0 to make sure it represents a fully-qualified path.
$0 = join('/', $ENV{PWD} || fastcwd(), $0) if $0 !~ m%^[/\\]|^[a-z]:\\%i;

# Convert any backslashes in $0 to forward slashes for consistency.
$0 =~ s%\\%/%g if $Win32;

# Now determine the name we were run as.
($Wrapper) = reverse split '/', $0;

# Remember if we're in a setuid situation.
$Setuid = ($< != $>) unless $Win32;

# Set up the hash %Vgra as a reverse lookup into @ARGV for
# ease in checking whether a given option was used.
%Vgra = ();
for (0..$#ARGV) {
   # Hack - while here, we add an extra set of quotes to any comment
   # passed in with -c on Windows; -c is such a ubiquitous flag 
   # that we might as well deal with it in one (hacked) place.
   $ARGV[$_+1] = qq("$ARGV[$_+1]") if $ARGV[$_] eq '-c';
   $Vgra{$ARGV[$_]} = $_;
}

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
$ClearCmd = 'cleartool' if ! -f $ClearCmd;

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
      $^W = 0;
      exec(@_);
      # if caller checks for return, respect that decision
      Die "$_[0]: $!" unless defined wantarray;
   }
}

=item * System(LIST)

A wrapper for system() which handles printing of debug tracing.
Dies automatically on command failure in void context. For easier
portability between Unix and Windows, this version supports literal
'>/dev/null' and '2>/dev/null' argument B<in list mode>.

=cut

sub System
{
   my @cmd   = grep !m%/dev/null$%, @_;
   my @nulls = grep  m%/dev/null$%, @_;
   my $rc;
   Dbg("system: @cmd", 1);
   for (@nulls) {
      if (/^2/) {
	 open(SAVE_STDERR, ">&STDERR") || warn "STDERR: $!";
	 close(STDERR);
      } else {
	 open(SAVE_STDOUT, ">&STDOUT") || warn "STDOUT: $!";
	 close(STDOUT);
      }
   }
   $rc = system(@cmd) & 0xffff;
   for (@nulls) {
      if (/^2/) {
	 open(STDERR, ">&SAVE_STDERR") || warn "STDERR: $!";
      } else {
	 open(STDOUT, ">&SAVE_STDOUT") || warn "STDOUT: $!";
      }
   }
   if (defined wantarray) {
      return $rc;
   } else {
      exit $rc>>8|$rc if $rc;
   }
}

=item * Qx(LIST)

A replacement for `cmd` with no shell needed, as suggested in Camel5.
Also more secure in setuid usage. Made available here for use in
profiles. On NT this is just a synonym for qx() since no fork().

=cut

sub Qx
{
   Dbg("Qx: @_", 1);
   # No fork() on &^&#@$ Win32.
   if ($Win32) {
      return qx(@_);
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
creation/removal is handled here automatically.  Parameters are the
same as the args for the clearprompt command except that no -out flag
is needed.

=cut

# NOTE: THIS IS A COPY of the function in ClearCase::Msg. At some future
# time we should simply 'use' that module and get it that way.
sub Prompt
{
   my $mode = shift;
   my @args = @_;

   # Aid in finding clearprompt.
   my $ccd = $ENV{ATRIAHOME} || ($^O =~ /win32/i ? 'C:/atria' : '/usr/atria');
   my $cpt = -d $ccd ? join('/', $ccd, 'bin', 'clearprompt') : 'clearprompt';

   # On Windows we must add an extra level of escaping to the prompt string
   # since all forms of system() appear to go through the ^#$& cmd shell!
   if ($^O =~ /win32/i) {
      for my $i (0..$#args) {
	 if ($args[$i] =~ /^-pro/) {
	    $args[$i+1] =~ s/"/'/gs;
	    $args[$i+1] = qq("$args[$i+1]");
	    last;
	 }
      }
   }

   # For clearprompt modes in which we get textual data back via a file,
   # derive here a reasonable temp-file name and handle the details
   # of reading data back out of it and unlinking it when done.
   # For other modes, just fire off the cmd and return the status.
   # In a void context, don't wait for the button to be pushed; just
   # fork and proceed asynchonously, since this is presumably just an
   # informational message.
   if ($mode =~ /text|file|list/) {
      my $outf = "$TmpDir/clearprompt.$$.$mode";
      system($cpt, $mode, '-out', $outf, @args) && die "$cpt: $!";
      open(OUTFILE, $outf) || die "$outf: $!";
      local $/ = undef;
      my $data = <OUTFILE>;
      close(OUTFILE);
      unlink $outf;
      return $data;
   } else {
      # Never proceed asynchronously in a command-line env ...
      if (defined wantarray || !$ENV{ATRIA_FORCE_GUI}) {
	 system($cpt, $mode, @args);
	 return $?>>8;
      } else {
	 if ($^O =~ /win32/i) {
	    system(1, $cpt, $mode, @args);
	 } else {
	    return if fork;
	    exec($cpt, $mode, @args);
	 }
      }
   }
}

=item * DosGlob(LIST)

On Windows, do the user a favor and handle globbing for DOS shell (as
well as possible).  Should generally be used after parsing options out
of the list so C<'-c "changed foo from char * to void *"'> doesn't get
modified.  Idea courtesy of Kenneth Olwing <K.Olwing@abalon.se>.

Takes a reference to a list plus an optional following list. Returns a
globbed list. The optional list, if present, is treated as a list of
option flags we want to parse off the argv before globbing what
remains.

=cut

sub DosGlob {
   my $r_ARGV = shift;
   if ($Win32) {
      # parse out supplied flags before globbing
      local @ARGV = @$r_ARGV;
      my($r_opts, $r_elems);
      if (@_) {
	 ($r_opts, $r_elems) = SplitArgv(@_);
      } else {
	 $r_elems = \@ARGV;
      }
      my @_argv = ();
      for (@$r_elems) {
	 if (/^'(.*)'$/) {		# allow '' to escape globbing
	    push(@_argv, $1);
	 } elsif (/[*?]/) {
	    push(@_argv,  glob)
	 } else {
	    push(@_argv, $_)
	 }
      }
      # Now quote filenames with whitespace for when they get exposed to
      # another DOS shell.
      for (@_argv) { $_ = qq("$_") if /\s/ }
      # And put back the flags.
      splice(@_argv, 1, 0, @$r_opts) if $r_opts;
      Dbg("ARGV globbed to '@_argv'", 1) if @ARGV != @_argv;
      return @_argv;
   } else {
      return @$r_ARGV;
   }
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
returning the stripped elements as a list (retaining order).

=cut

sub StripOptions
{
   my $r_argv = shift; # not used, here for consistency with the other funcs.
   my @orig = @ARGV;
   my %null = ();
   Getopt::Long::GetOptions(\%null, @_);
   my %vgra = ();
   for (0..$#ARGV) { $vgra{$ARGV[$_]} = 1 }
   my @stripped = ();
   for (@orig) { push(@stripped, $_) unless $vgra{$_} }
   return @stripped;
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

=item 4. SplitArgv(LIST)

Uses GetOptions to break the current scope's @ARGV into two arrays,
a list of options and a list of arguments, and returns references to
them. Example:

    my($r_opts, $r_args) = SplitArgv(qw(c|cfile=s cq|cqe|nc));

would assign any of the standard comment flags C<(-c, -nc, etc.)> to the array
known as @$r_opts, and any remaining arguments (presumably element names)
to @$r_args. Normally you'd want to pass it the full list of options
accepted by the current ClearCase command, of course.

The syntax is identical to that for Getopt::Long::GetOptions(). Notice 
that we cluster flags of like type together as if they were synonyms even
when they're not; this is ok since we're only interested in finding the
right number of them, not in applying any semantics here.

=cut

sub SplitArgv(@)
{
   my @orig = @ARGV;
   local @ARGV = @ARGV;
   my(@opts, %null, %vgra);

   Getopt::Long::GetOptions(\%null, @_);
   for (0..$#ARGV) { $vgra{$ARGV[$_]} = 1 }
   for (@orig) { push(@opts, $_) unless $vgra{$_} }
   return (\@opts, \@ARGV);
}

=back

=cut

1;
