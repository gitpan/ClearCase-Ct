#!/usr/local/bin/perl	# for doc purposes only, not executable as is

use vars qw($VERSION);

# Note: this version may move independently of the one in Ct.pm.
$VERSION = '1.08';

=head1 NAME

Profile.pm - site-wide customizations for B<ct> wrapper

=head1 SYNOPSIS

This perl module functions as a
wrapper for B<cleartool>, allowing the command-line interface of
B<cleartool> to be extended or modified. It allows defaults to be
changed, new flags to be added to existing B<cleartool> commands, or
entirely new B<cleartool> commands to be synthesized.

Unfortunately, there's no equivalent mechanism for wrapping GUI access
to clearcase.

=head1 SUMMARY

Here's a quick overview of the extensions available via B<ct> which may
be of interest to users:

Many I<cleartool> commands have been enhanced to simulate the standard
flags B<-dir>, B<-rec>, and B<-all>, which cause the command to operate
on (respectively) all eligible elements in the current dir, the current
dir recursively, and the current vob. The enhanced commands include
B<checkin/ci>, B<unco>, B<diff>, B<mkelem>, and B<lsprivate>.  Thus you
can check in all your current checkouts with B<ct ci -all> or see the
view-private files in and under the current dir with B<ct lsprivate
-rec>. You can convert a tree of view-private data into elements with
B<ct mkelem -rec -ci>.

The B<ct checkin> command is also enhanced to take a B<-diff> flag which
prints your changes to the screen before prompting for a comment.

A new command B<ct edit> is added. This is the same as B<ct checkout>
but execs your favorite editor after checking out. It also takes a
B<-ci> flag which will check the file in afterwards.

All commands which take a B<-tag I<view-tag>> option are enhanced to
recognize the B<-me> flag.  This modifies the effect of B<-tag> by
prepending your username to the view name. E.g.  B<-tag I<foo> -me> is a
shorthand for B<-tag I<E<lt>usernameE<gt>_foo>>.  Similarly,
B<ct lsview -me> will show only views whose names match the pattern
I<E<lt>B<username>E<gt>_*>.

The B<ct mkview> command is enhanced to default the view-storage
location to a standard place using a standard naming convention.  See
I<SiteProfile.pm.sample> for how this is set up.  Also, B<mkview>
recognizes the B<-me> flag as described above. This means that making a
new view can/should be done as B<ct mkview -tag foo -me>.

New pseudo-commands B<ct edattr> and B<ct edcmnt> are added. These
make it easy to edit the attributes and comments, respectively, of
a particular version.

A new command B<ct rmpriv> is added, which behaves like
C<B<rm -i `ct lsprivate -rec`>>, though B<-dir> or B<-all> may be
substituted for B<-rec> and B<-f> may be passed to override B<-i>.

Detailed descriptions of all the above may be found below. Summaries
are available via the standard B<-h> flag.

=head1 DESCRIPTION

=cut

########################################################################
# Notes for Developers:
# This file is in two sections.  The first section simply adds help
# data for the commands modified/defined in the second section; it's
# placed first both for self-documentation reasons and so we can return
# before reaching the command section when in help mode.

# The help section is where extensions are documented.  Assigning string
# data to $Help{command} will cause the new string to be printed after
# the "real" help output, if any, for that cmd.  If you're adding a whole
# new cmd, there will be no "real" output so you can provide the entire
# help msg here. By convention, new flags are marked with a (*).

# The command section is in the form of a series of blocks, one
# for each command name we want to recognize and modify. In a few
# complex cases there may even be multiple different blocks for a
# command but generally this is not necessary. Typically each
# block ends with a 'last COMMAND' for performance reasons (to
# keep perl from having to examine the remaining blocks for a
# nonexistent match.

# The command section also defines some useful subroutines and
# global data at the top.

# Sorry, this file is not too well documented and not to everyone's
# taste stylistically. The good news is that most of the code blocks
# are completely standalone so it's not too hard to figure out what
# they do once you understand that. Think of them as subroutines; they
# have @_ set upon entry (as well as $_ set to the command name).
########################################################################

######################### Help Section #################################

# We always want to traverse this block, even if help is not being
# requested, in order to have a full record of the usage msgs so a
# pseudo-command can print it on error. The keys below must be the
# real name of the cmd, not an abbreviation!
{

   $Help{catcs} .= "
           * [-expand|-source|-branch|-vobs|-project|-promote]";

   $Help{checkin} .= "
                  * [-dir|-rec|-all] [-diff [diff-options]] [-revert]";

   $Help{diff} .= "
          * [-c] [-dir|-rec|-all]";

   $Help{edit} .= "Usage: *edit <co-flags> [-ci] <ci-flags> pname ...";

   $Help{find} .= "
          * [-fmt format] (simulated by passing output to 'describe')";

   $Help{lsprivate} .= "
               * [dir]
               * [-dir|-rec|-all]";

   $Help{lsview} .= "
            * [-me]";

   $Help{mkelem} .= "
            * [-dir|-rec]";

   $Help{mkview} =~ s/  (view-storage-pname)/* [-me] [-back backing-view-list | -profile view-profile-name]
            * [$1]/;

   $Help{setview} .= " * [-me]";

   $Help{uncheckout} .= "
                       * [-nc]";

   $Help{synccs} .= "Usage: *synccs [-tag view-tag] -profile profile-name";

   $Help{edattr} .= "Usage: *edattr object-selector ...";

   $Help{edcmnt} .= "Usage: *edcmnt [-new] object-selector ...";
}

###################### End of Help Section #############################

####################### Command Section ################################

use subs qw(Die Warn);	# keeps perl -c happy

# Override the user's preferences while interacting with clearcase.
umask 002;

# Just in case we need to do a 'mkdir -p' type of thing.
use autouse 'File::Path' => qw(mkpath);

# Assume that all vobs are owned by a single pseudo-user of this name:
my $VobAdm = 'vobadm';

# General-purpose accumulator for CT options.
my %Opt;

# Examines current ARGV, returns the specified or current view tag.
sub ViewTag
{
   local(@ARGV) = @ARGV;
   my($opt_view_tag);
   GetOptions("tag=s" => \$opt_view_tag);
   ($opt_view_tag) = reverse split('/', $ENV{CLEARCASE_ROOT}) if !$opt_view_tag;
   return $opt_view_tag;
}

# Takes the name of a view tag, returns the storage dir for that view.
sub ViewStorage
{
   my($tag) = @_;
   my $vws;
   my @lsview = Backtick($0, 'lsview', $tag);
   chomp @lsview;
   if ($lsview[0] =~ m%.*\s(\S*)%) { $vws = $1; }
   return $vws;
}

# Implements a global convenience/standardization feature: the flag -me
# in the context of a command which takes a view-tag with -tag causes
# "$LOGNAME" to be prefixed to the tag name with an underscore.  This
# relies on the fact that even though -me is a native cleartool flag,
# as of CC3.2 no command which takes -tag also takes -me natively.
if ((grep /^-me$|^-tag$/, @ARGV) >= 2) {
   my($opt_gen_tag, $opt_gen_me);
   ReadOptions(\@ARGV, "tag=s" => \$opt_gen_tag, "me" => \$opt_gen_me);
   if ($opt_gen_me && $opt_gen_tag && ($opt_gen_tag !~ m%/%)) {
      $ARGV[$Vgra{'-tag'}+1] = join('_', $ENV{LOGNAME}, $opt_gen_tag);
      StripOptions(\@ARGV, "me");
   }
}

# Format: Each block below represents a command name which can
# follow 'cleartool'. These may be existing commands whose
# default behavior we want to modify or supplement, or they may
# be meta-commands which are implemented entirely in the wrapper.
# The intent is that we should enter exactly one or none of these
# blocks, not counting a global arg-parsing block or two at the top.
# These blocks are documented "in the large" via pod blocks, with
# smaller local comments where B<absolutely> necessary :-)

COMMAND: {

   # No need to parse all the remaining code if only help msg was wanted.
   last COMMAND if /^help$/ || $Cmd_Help;

   # This block handles initializations for the -dir/-rec/-all
   # extension of all the cmds matched by the pattern below.
   # Performance hack: enter this block only if a simple-minded RE
   # tells us we have a chance of finding a -dir/-rec/-all flag.
   if (/^ci$|^checkin$|^co$|^checkout$|^edit$|^unc
	       |^diff$|^review$|^mkelem$|^lsp|^rmpriv/x
	    && grep /-[dra]/, @ARGV) {
      GetOptions(\%AutoOpt, "directory", "recurse", "all");
      if (keys %AutoOpt > 1) {
	 my @temp = join(' -', keys %AutoOpt);
	 die "conflicting flags:  -@temp\n";
      }

      # Anonymous local sub to print out the set of elements we
      # derived as 'eligible'.
      my $showfound = sub {
	 if (@_ == 0) {
	    warn "$ARGV[0]: no eligible elements found\n";
	    exit 0;
	 } elsif (@_ <= 10) {
	    warn "$ARGV[0]: found: @_\n";
	 } elsif (@_) {
	    my $i = @_ - 4;
	    warn "$ARGV[0]: found: @_[0..3] [plus $i more] ...\n";
	 }
      };

      # Return the list of checked-out elements according to
      # the -dir/-rec/-all flags. Takes a ref to an ARGV plus
      # a list of flags to strip from it before running lsco.
      sub CheckedOutList {
	 my $r_argv = shift;
	 my @t_argv = RemainingOptions($r_argv, @_);
	 my @new_elems;
	 # Get rid of the cmd name.
	 shift @t_argv;
	 # The FAQ says this is slow but it's a very small array ...
	 unshift(@t_argv, '-cvi') unless grep /^-cvi/, @t_argv;
	 unshift(@t_argv, '-s') unless grep /^-s/, @t_argv;
	 if ($AutoOpt{all}) {
	    @new_elems = Backtick($0, 'lsco', '-all', @t_argv);
	 } elsif ($AutoOpt{recurse}) {
	    @new_elems = Backtick($0, 'lsco', '-r', @t_argv);
	 } elsif ($AutoOpt{directory}) {
	    @new_elems = Backtick($0, 'lsco', @t_argv);
	 }
	 chomp @new_elems;
	 &$showfound(@new_elems);
	 return @new_elems;
      }

      sub PrivateList {
	 my @cmd = ($0, 'lsp', '-s', @_);
	 if ($AutoOpt{all}) {
	    push(@cmd, '-all');
	 } elsif ($AutoOpt{recurse}) {
	    push(@cmd, '-rec');
	 } elsif ($AutoOpt{directory}) {
	    push(@cmd, '-dir');
	 }
	 my @new_elems = Backtick(@cmd, '--reread');
	 chomp @new_elems;
	 &$showfound(@new_elems);
	 return @new_elems;
      }

      ## No 'last COMMAND' here; it's just an initializer block
   }

# Begin embedded pods

=over 4

=item * CATCS

Lots of enhancements here, mostly in the area of config-spec parsing
for automation:

=over 4

=item 1. New B<-expand> flag

This follows all include statements recursively in order to print a
complete config spec.

=item 2. New B<-source> flag

Prints the I<initial working directory> of a view by examining its
config spec. If the conventional string C<##:Source: I<dir>> is present
then the value of I<dir> is printed. Otherwise the first path
found in the second field of the config spec, typically a vob tag,
is used. If no explicit paths are present, no output is produced.

=item 3. New B<-branch> flag

Prints the name of the first branch selected in the config spec
via a line like this:

	C<element * .../I<branch>/LATEST>

=item 4. New B<-vobs> flag

Prints a list of all vob tags referenced explicitly within the
config spec.

=item 5. New B<-project> flag

Prints the I<name> of the first vob tag encountered in the config spec,
assuming the vob-naming convention C</vobs/I<name>/src> or
C</vobs/I<name>/do> (meaning C<source vobs> and C<derived-object> vobs
respectively).

=item 6. New B<-promote> flag

Prints the name of the I<backing branch> of the current config spec.
This is the branch that local work will be merged to.

=back

=cut

   if (/^catcs$/) {

      # Function to parse 'include' stmts recursively.  Used by
      # config-spec parsing meta-commands. The first arg is an
      # open filehandle, the second is a string which is eval-ed
      # for each line.  It can be as simple as 'print' or as
      # complex a regular expression as desired.
      sub burrow {
	 my($input, $action) = @_;
	 while (<$input>) {
	    if (my($next) = /^include (.*)/) {
	       # See Camel5 pg 79, search for 'magical'.
	       local($i) = $input; $i++;
	       print "# $_" unless $action;
	       if (open($i, $next)) {
		  burrow($i, $action);
		  close $i;
	       }
	       next;
	    }
	    eval $action;
	 }
      }

      GetOptions(\%Opt, "expand", "branch", "project", "projlist",
			"promote=s", "source", "vobs");
      my $op;
      if ($Opt{expand}) {
	 $op = 'print';;
      } elsif ($Opt{source}) {
	 $op = 's%##:Source:\s+(\S+)|element\s+(\S*)/\.{3}\s%print "$+\n";exit 0%e';
      } elsif ($Opt{vobs}) {
	 $op = 's%^element\s+(\S+)/\.{3}\s%print "$1\n"%e';
      } elsif ($Opt{project}) {
	 $op = 's%^element\s+/vobs/([^/]*)/src/\.{3}\s%print "$1\n";exit 0%e';
      } elsif ($Opt{projlist}) {
	 $op = 's%^element\s+/vobs/([^/]*)/src/\.{3}\s%print "$1\n"%e';
      } elsif ($Opt{branch}) {
	 $op = 's%^element\s+\S+\s+.*/([^/]*)/LATEST%print "$1\n";exit 0%e';
      } elsif ($Opt{promote}) {
	 $op = 's%^element\s+$Opt{promote}/\.+\s+.*/([^/]*)/LATEST%print "$1\n";exit 0%e';
      }
      if ($op) {
	 my $handle = 'CATCS_00';
	 if (open($handle, "-|")) {
	    burrow($handle, $op);
	    close($handle);
	    exit $?>>8;
	 } else {
	    Exec($ClearCmd, @ARGV);
	 }
      }
      last COMMAND; #NOTREACHED#
   }

=item * CI/CHECKIN

Extended to handle the B<-dir/-rec/-all> flags.

Extended to allow symbolic links to be "checked in" (by simply
checking in the target of the link instead).

Extended to implement a B<-diff> flag, which runs a B<ct diff -pred>
command before each checkin so the user can look at his/her changes
before typing the comment.

=cut

   if (/^ci$|^checkin$/) {
      # Extension: handle AutoOpt flags (parsed above).
      push(@ARGV, CheckedOutList(\@ARGV,
			      "c|cfile=s", "cqe|nc",
			      "nwarn|cr|ptime|identical|rm", "from=s",
			      "diff|graphical|tiny|hstack|vstack|predecessor",
			      "serial_format|diff_format|window",
			      "columns|options=s"))
	    if (keys %AutoOpt);

      # If the user tries to check in a symlink, replace it with
      # the path to the actual element. Same as at checkout time.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      # It's too easy for users to kill a putative checkin-post
      # trigger via Ctrl-C. We don't want to ignore all
      # signals, just the one which is easy to send via the
      # keyboard - i.e. make them do a kill -HUP if they really need to
      # kill the trigger.
      $SIG{INT} = 'IGNORE';	## this does not appear to be effective

      # Extension: -d/iff flag runs 'cleartool diff' on each elem first
      my($opt_ci_diff, $opt_ci_revert);
      GetOptions("diff" => \$opt_ci_diff, "revert" => \$opt_ci_revert);
      if ($opt_ci_diff) {
	 my(@elems, @diff_args);
	 {
	    local (@ARGV) = @ARGV;	# operate on temp argv
	    shift;			# ignore command name
	    # Remove checkin flags from this temp copy of argv
	    StripOptions(\@ARGV, "cqe|nc|nwarn|cr|ptime|identical|rm",
			 "c|cfile|from=s");
	    # Assuming the elements come after remaining flags, figure
	    # out where they start.
	    @elems = RemainingOptions(\@ARGV,
		     "serial_format|diff_format|window",
		     "graphical|tiny|hstack|vstack|predecessor", "options=s");
	    my $start = @ARGV - @elems;
	    # The part of the argv before the element list must be diff-flags.
	    @diff_args = @ARGV[0..$start-1] || ('-serial');
	 }
	 # Strip diff options from argv since we've captured them elsewhere.
	 StripOptions(\@ARGV, "serial_format|diff_format|window",
		  "graphical|tiny|hstack|vstack|predecessor", "options=s");
	 # Strip element list since we have it - what remains is checkin opts.
	 splice(@ARGV, @ARGV - @elems);
	 if (@elems) {
	    for $elem (@elems) {
	       my $diff = System($ClearCmd, qw(diff -pred), @diff_args, $elem);
	       # If -revert and no diffs, uncheckout instead of checkin
	       if ($opt_ci_revert && !$diff) {
		  System($ClearCmd, qw(unco -rm), $elem);
	       } else {
		  System($ClearCmd, @ARGV, $elem);
	       }
	    }
	    # All done, no need to return to wrapper program.
	    exit $?>>8;
	 }
      }
      last COMMAND;
   }

=item * CO/CHECKOUT

Extension: if element being checked out is a symbolic link,
silently replace it with the name of its target, because for
some reason ClearCase doesn't do this automatically.

=item * EDIT

Convenience command. Same as 'checkout' but execs your favorite editor
afterwards. Takes all the same flags as checkout, plus B<-ci> to check
the element back in afterwards. When B<-ci> is used in conjunction with
B<-diff> the file will be either checked in or un-checked out depending
on whether it was modified.

Also, B<ct edit -dir> will not check anything out but will exec the
editor on all currently checked-out files.

=cut

   if (/^co$|^checkout$|^edit$/) {
      # If the user tries to check out a symlink, replace it with
      # the path to the actual element. Don't know why CC doesn't
      # do this or at least provide a -L flag.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      if (/^edit$/) {
	 # Special hack - -dir/-rec execs editor on current checkouts
	 Exec($Editor, CheckedOutList(\@ARGV)) if keys %AutoOpt;

	 # First, parse for the pseudo flag -ci but only if we know
	 # it's there.
	 my($opt_edit_ci);
	 GetOptions("ci" => \$opt_edit_ci) if defined $Vgra{-ci};

	 # Now strip the checkin options from @ARGV if -ci was used,
	 # saving them for the checkin.
	 my @ci_options = StripOptions(\@ARGV, "nwarn|cr|ptime|identical|rm",
					    "from=s", "diff") if $opt_edit_ci;

	 # Do the checkout.
	 if (System($ClearCmd, 'co', @ARGV[1..$#ARGV])) {
	    Prompt('text', '-pro', "[Hit return to continue]");
	 }

	 # Now we can strip all 'co' flags from ARGV; what's left
	 # should be elements only.
	 StripOptions(\@ARGV, "out|branch=s", "c|cfile=s", "cqe|nc",
			   "reserved|unreserved|ndata|version|nwarn");
	 shift @ARGV;

	 # Edit the file(s) and checkin afterwards if -ci was used.
	 if ($opt_edit_ci) {
	    System($Editor, @ARGV) || 1; ## ignore $? - vi sometimes exits >0
	    Exec($0, qw(ci -revert --reread), @ci_options, @ARGV);
	 } else {
	    Exec($Editor, @ARGV);
	 }
	 #NOTREACHED#
      }

      last COMMAND;
   }

=item * DIFF

Modified default: if no flags given, assume -pred.

Extended to handle the B<-dir/-rec/-all> flags.  Also adds a B<-c> flag
to generate a context diff (by simply using the real diff program).

=cut

=item * REVIEW

New convenience command: sends a context diff between current and
previous versions to the 'pprint' program, which prints it with line
numbers appropriate for code reviews. E.g. you could generate a listing
of all changes currently checked-out in your view with C<ct review -all>.

=cut

   if (/^diff$|^review$/) {
      my(@elems);
      my @diff_flags = ("serial_format|diff_format|window",
			"graphical|tiny|hstack|vstack|predecessor",
			"options=s");

      GetOptions(\%Opt, 'c', 't=s');

      if (/^review$/) {
	 $Opt{c} = 1;
	 $Opt{t} ||= 'Code Review';
      }

      if (keys %AutoOpt) {
	 @elems = CheckedOutList(\@ARGV, @diff_flags);
      } else {
	 @elems = RemainingOptions(\@ARGV,  @diff_flags);
	 shift @elems;
      }

      if ($Opt{c}) {
	 my $finalstat = 0;
	 for my $elem (@elems) {
	    my $pred = `$ClearCmd desc -short -pred $elem`;
	    chomp $pred;
	    if (/^review$/) {
	       open(STDOUT, "| pprint -t '$elem'") || Warn "$!";
	    }
	    my $rc = System('/usr/bin/diff', '-c', "$elem\@\@$pred", $elem);
	    if ($rc>>8 > 1) {
	       $finalstat = 2;
	    } elsif ($rc>>8 == 1 && $finalstat < 2) {
	       $finalstat = 1;
	    }
	 }
	 exit $finalstat;
      }

      # Extension: handle AutoOpt flags (parsed above).
      if (keys %AutoOpt) {
	 my $rc = 0;
	 for my $elem (@elems) { $rc = System($0, @ARGV, '--reread', $elem) }
	 exit $rc>>8;    # All done, no need to return to wrapper program.
      }

      # Change default: diff -pred -serial
      splice(@ARGV, 1, 0, '-pred', '-serial') if @elems == 1;
      last COMMAND;
   }

=item * EDATTR

New command, inspired by the B<edcs> cmd.  Analogous to B<edcs>,
B<edattr> dumps the attributes of the specified elements into a temp
file, then execs your favorite editor on it, and adds, removes or
modifies the attributes as appropriate after you exit the editor.
Attribute types are created and deleted automatically.  This is
particularly useful on Unix platforms because as of CC 3.2 the Unix GUI
doesn't support modification of attributes.

=cut

   if (/^edattr$/) {
      Die "$Help{$_}\n" unless @ARGV > 1;
      my $retstat = 0;
      my $edtmp = "$TmpDir/$_.$$";
      for my $elem (@ARGV[1..$#ARGV]) {
	 my %indata = ();
	 $elem .= '@@' unless $elem =~ /\@\@/;
	 my @lines = `$ClearCmd desc -aattr -all $elem`; 
	 if ($?) {
	    $retstat++;
	    next;
	 }
	 for my $line (@lines) {
	    next unless $line =~ /\s*(\S+)\s+=\s+(.+)/;
	    $indata{$1} = $2;
	 }
	 open(EDTMP, ">$edtmp") || die "$edtmp: $!";
	 print EDTMP "# $elem (format: attr = \"val\"):\n\n" if ! keys %indata;
	 for (sort keys %indata) { print EDTMP "$_ = $indata{$_}\n" }
	 close(EDTMP) || die "$edtmp: $!";

	 # Run editor on temp file
	 System($Editor, $edtmp) || 1; ## ignore $? - vi sometimes exits >0

	 open(EDTMP, $edtmp) || die "$edtmp: $!";
	 while (<EDTMP>) {
	    chomp;
	    next if /^\s*$|^\s*#.*$/;	# ignore null and comment lines
	    if (/\s*(\S+)\s+=\s+(.+)/) {
	       my($attr, $val) = ($1, $2);
	       my $oldval = $indata{$attr};
	       delete $indata{$attr};
	       # Skip if unchanged.
	       next if $oldval eq $val;
	       # Figure out what type the new attype needs to be.
	       # Sorry, didn't bother with -vtype time.
	       if (System("$ClearCmd lstype attype:$attr >$DevNull 2>&1")) {
		  if ($val =~ /^".*"$/) {
		     System($ClearCmd, qw(mkattype -nc -vty string), $attr);
		     $val = "\\\"$val\\\"" if $Win32;
		  } elsif ($val =~ /^[+-]?\d+$/) {
		     System($ClearCmd, qw(mkattype -nc -vty integer), $attr);
		  } elsif ($val =~ /^-?\d+\.?\d*$/) {
		     System($ClearCmd, qw(mkattype -nc -vty real), $attr);
		  } else {
		     System($ClearCmd, qw(mkattype -nc -vty opaque), $attr);
		  }
	       }
	       $retstat++
		  if System($ClearCmd, qw(mkattr -replace), $attr, $val, $elem);
	    } else {
	       $retstat++;
	       Warn "$ARGV[0]: incorrect line format: '$_'";
	    }
	 }
	 close(EDTMP) || die "$edtmp: $!";

	 # Now, delete any attrs that were deleted from the temp file.
	 # First we do a simple rmattr; then see if it was the last of
	 # its type and if so remove the type too.
	 for (sort keys %indata) {
	    if (System($ClearCmd, 'rmattr', $_, $elem)) {
	       $retstat++;
	    } else {
	       System($ClearCmd, 'rmtype', '-rmall', "attype:$_");
	    }
	 }
      }
      unlink $edtmp;
      exit $retstat;
   }

=item * EDCMNT

Similar to B<edattr>. For each version specified, dump the comment
into a temp file, allow the user to edit it with his/her favorite editor,
then change the version's comment to the results of the edit. The B<-new>
flag causes it to ignore the previous comment.

=cut

   if (/^edcmnt$/) {
      my($opt_edcmnt_new);
      GetOptions("new" => \$opt_edcmnt_new);
      Die "$Help{$_}\n" unless @ARGV > 1;
      my $retstat = 0;
      my $edtmp = "$TmpDir/$_.$$";
      # Checksum before and after edit - only update if changed.
      my($csum_pre, $csum_post);
      for my $elem (@ARGV[1..$#ARGV]) {
	 my @input = ();
	 if (!$opt_edcmnt_new) {
	    @input = Backtick($ClearCmd, qw(desc -fmt %c), $elem);
	    next if $?;
	 }
	 open(EDTMP, ">$edtmp") || Die "$edtmp: $!";
	 for (@input) {
	    $csum_pre += unpack("%16C*", $_);
	    print EDTMP $_;
	 }
	 close(EDTMP) || Die "$edtmp: $!";
	 System($Editor, $edtmp) || 1; ## ignore $? - vi sometimes exits >0
	 open(EDTMP, $edtmp) || Die "$edtmp: $!";
	 while (<EDTMP>) { $csum_post += unpack("%16C*", $_); }
	 close(EDTMP) || Die "$edtmp: $!";
	 next if $csum_post == $csum_pre;
	 if (System($ClearCmd, qw(chevent -replace -cfi), $edtmp, $elem)) {
	    $retstat++;
	    next;
	 }
      }
      unlink $edtmp;
      exit $retstat;
   }

=item * RMPRIV

New convenience command. Conceptually this is just a shorthand for
B<"rm -i `ct lsp`">, but it also handles convenience features such as the
rm-like B<-f> flag plus B<-dir/-rec/-all>.  It has the benefit of
behaving the same way on NT as well.

=cut

   if (/^rmpriv/) {
      Die "$ARGV[0]: must use one of -dir/-rec/-all\n" unless keys %AutoOpt;
      GetOptions("i" => \$opt_i, "f" => \$opt_f);
      for my $inode (reverse PrivateList(qw(-other -do))) {
	 if ($opt_i || ! $opt_f) {
	    $_ = Prompt('text', '-pro', "$ARGV[0]: remove $inode (yes/no)? ");
	    next unless /y/i;
	 }
	 if (-d $inode) {
	    rmdir $inode || Warn "$inode: $!\n";
	 } else {
	    unlink $inode || Warn "$inode: $!\n";
	 }
      }
      exit;
   }

=item * FIND

Extended to simulate the -fmt option.  This is done by sending the
results of B<find> to a B<describe -fmt>.

=cut

   if (/^find$/) {
      # Extension: simulate -fmt option by passing output to ct desc,
      # which supports -fmt.
      GetOptions("fmt=s" => \$opt_fmt);
      if ($opt_fmt) {
	 if (my @conflict = grep /^-print|^-exec|^-ok/, @ARGV) {
	    Warn "-fmt flag conflicts with @conflict\n";
	 }
	 Exec("$ClearCmd @ARGV -print |
	       /usr/bin/xargs $ClearCmd desc -fmt '$opt_fmt'");
      }
      last COMMAND;
   }

=item * LSCO

Modified default: if no flags supplied, pass B<-cview>.

=cut

   if (/^lsco$/) {
      # Change default: use lsco -cview unless other flags supplied.
      splice(@ARGV, 1, 0, '-cview') if $#ARGV == 0;
      last COMMAND;
   }

=item * LSVTREE

Modified default to always use B<-a> flag.

=cut

   if (/^lsvt/) {
      # Change default: default to lsvtree -a mode.
      splice(@ARGV, 1, 0, '-a') if !grep(/^-a/, @ARGV);
      last COMMAND;
   }

=item * LSPRIVATE

Extended to recognize B<-dir/-rec/-all> (underlying lsprivate always
behaves in a B<-all> fashion). Also allows a directory to be
specified, such that 'ct lsprivate .' restricts output to cwd.

=cut

   if (/^lsp/) {
      # Extension: allow [dir] argument
      if (RemainingOptions(\@ARGV, "co|do|other|short|long",
					     "tag|invob=s") == 2) {
	 chdir(pop @ARGV) || die "$ARGV[0]: $!\n";
	 $AutoOpt{recurse} = !$AutoOpt{directory};
      }

      # Extension: allow [-dir|-rec|-all]
      if ($AutoOpt{recurse} || $AutoOpt{directory}) {
	 my $dir = fastcwd();
	 $dir =~ s/^[A-Z]:// if $Win32;
	 my @privs = sort `$ClearCmd @ARGV`;
	 for (@privs) { s%\\%/%g }
	 if ($AutoOpt{recurse}) {
	    print map {$_ eq "\n" ? ".\n" : $_}
		  map {m%^$dir/(.*)%s} 
		  map {$_ eq $dir ? "$dir/" : $_} @privs;
	 } elsif (! $AutoOpt{all}) {
	    print map {$_ eq "\n" ? ".\n" : $_}
		  map {m%^$dir/([^/]*)$%s}
		  map {$_ eq $dir ? "$dir/" : $_} @privs;
	 }
	 exit;
      }

      last COMMAND;
   }

=item * LSVIEW

Extended to recognize the general B<-me> flag, restricting the search
namespace to E<lt>B<username>E<gt>_*.

=cut

   if (/^lsview$/) {
      my($opt_lsview_me);
      GetOptions("me" => \$opt_lsview_me);
      # For some reason usernames seem to be forced to uppercase on NT.
      push(@ARGV, $Win32 ? "$ENV{USERNAME}_*" : "$ENV{LOGNAME}_*")
	    if $opt_lsview_me;
      last COMMAND;
   }

=item * MKATTYPE

Modification: if user tries to make a type in the current VOB without
explicitly specifying -ordinary or -global, and if said VOB is
associated with an admin VOB, then by default create the type as a
global type in the admin VOB instead. B<In effect, this makes -global
the default iff a suitable admin VOB exists>.

=item * MKLBTYPE

Same as mkattype above.

=cut

   if (/^mkattype$|^mklbtype$/) {
      if (! grep(/^-ord|^-glo|vob:/i, @ARGV)) {
	 my $adm = `$ClearCmd desc -s -ahlink AdminVOB vob:.`;
	 if ($? == 0 && $adm) {
	    if ($adm =~ s/->\s+vob:(.+)/$1/) {
	       chomp $adm;
	       warn "Making global type in VOB $adm ...\n";
	       # Save aside all possible flags for mkattype/mklbtype,
	       # then add the vob selector to each type selector,
	       # and put the flags back along with the new -global.
	       my @flags = StripOptions(\@ARGV, "replace|global|ordinary",
			      "vpelement|vpbranch|vpversion",
			      "gt|ge|lt|le|enum|default|vtype=s",
			      "pbranch|shared",
			      "cqe|nc", "c|cfile=s");
	       for (@ARGV[1..$#ARGV]) {$_ .= "\@vob:$adm"}
	       splice(@ARGV, 1, 0, @flags, '-global');
	    }
	 }
      }
   }

=item * MKELEM

Extended to handle the -dir/-rec flags, enabling automated mkelems with
otherwise the same syntax as original. Directories are also
automatically checked out as required in this mode. Note that this
automatic directory checkout is only enabled when the candidate list is
derived via the -dir/-rec flags.  If the -ci flag is present, any
directories automatically checked out are checked back in too.

=cut

   if (/^mkelem$/) {
      # Extension: handle AutoOpt flags (parsed above).
      last COMMAND unless keys %AutoOpt;
      Die "flag not supported for command '$_'\n"
	    if $AutoOpt{all};

      # Derive the list of view-private files to work on.
      # Some files we don't ever want to put under version control...
      # this RE should really be passed as a parameter to PrivateList().
      my @candidates = grep(!/\Q.cmake.state\E|
			    \Q.mvfs_\E|
			    \Q.abe.state\E/x,
	    PrivateList('-other'));

      # We'll be separating the elements-to-be into files and directories.
      my @files = ();
      my %dirs = ();

      # If the parent directories of any of the candidates are
      # already versioned, we'll need to check them out unless
      # it's already been done.
      for (@candidates) {
	 my $d = dirname($_);
	 next if $dirs{$d};
	 my $lsd = `$ClearCmd ls -d $d`;
	 # If no version selector given, it's a view-private dir and
	 # will be handled below.
	 next unless $lsd =~ /\sRule:\s/;
	 # If already checked out, nothing to do.
	 next if $lsd =~ /CHECKEDOUT$/;
	 # Now we know it's an element and needs to be checked out.
	 $dirs{$d}++;
      }
      exit $?>>8 if keys %dirs && System($ClearCmd, qw(co -nc), keys %dirs);

      # Process candidate directories here, then do files below.
      for my $cand (@candidates) {
	 if (! -d $cand) {
	    push(@ARGV, $cand);
	    push(@files, $cand);
	    next;
	 }
	 # Now we know we're dealing with directories.  These cannot
	 # exist at mkelem time so we move them aside, make
	 # a versioned dir, then move all the files from the original
	 # back into the new dir (still as view-private files).
	 my $tmpdir = "$cand.$$.keep.d";
	 Die "$cand: $!" unless rename($cand, $tmpdir);
	 if(System($ClearCmd, qw(mkdir -nc), $cand)) {
	    rename($tmpdir, $cand);
	    exit 1;
	 }
	 opendir(DIR, $tmpdir) || Die "$tmpdir: $!";
	 while (defined(my $i = readdir(DIR))) {
	    next if $i eq '.' || $i eq '..';
	    rename("$tmpdir/$i", "$cand/$i") || Die "$cand/$i: $!\n";
	 }
	 closedir DIR;
	 Warn "$tmpdir: $!" unless rmdir $tmpdir;
	 # Keep a record of directories to be checked in when done.
	 $dirs{$cand}++;
      }

      # Now we've made all the directories - do the files in one
      # fell swoop.
      System($ClearCmd, @ARGV) if @files;

      # Now, if the -ci flag was supplied, check the dirs back in.
      my $opt_mkelem_ci;
      ReadOptions(\@ARGV, "ci" => \$opt_mkelem_ci);
      exit $?>>8
	 if $opt_mkelem_ci && keys %dirs &&
	    System($ClearCmd, qw(ci -nc), keys %dirs);

      exit 0;
   }


=item * MKVIEW

Extended in the following ways:

=over 4

=item 1. New I<-me> flag

Supports the I<-me> flag to prepend $LOGNAME to the view name,
separated by an underscore. This enables the convention that all user
views be named B<E<lt>usernameE<gt>_E<lt>whateverE<gt>>.

=item 2. Default view-storage location

Provides a standard default view-storage path which includes the user's
name. Thus a user can simply type B<"mkview -me -tag foo"> and the view
will be created as E<lt>usernameE<gt>_foo with the view storage placed
in a default location determined by the sysadmin.

=item 3. New I<-profile> flag

The user can associate the view with a I<ClearCase View Profile>.
Although, as of CC 3.2 these can only be manipulated on Windows NT,
this extension allows them to be I<used> on Unix platforms. In order
for this to work, the view-profile storage area must be accessible to
the Unix platforms (via NFS or Samba, for instance). The profile
text is modified to replace backslashes with forward slashes, correct
line-termination characters, and is then instantiated in the config
spec. The B<ct synccs> command can be used to resync.

#=item 4. New I<-back> flag
#This is an advanced topic ...

## Note: to use the default view-storage feature you must define
## the variable $ViewStgRoot to the appropriate place, typically
## /net/somewhere/viewstore/... or similar.

=back

=cut

   if (/^mkview$/) {
      # Policy: print warnings if new view's tag does not match the
      # local naming convention, or if the storage location is not
      # one of the approved areas.
      # Extension: if no view-storage area specified, use a standard one.
      my($opt_tag, $stg, $opt_profile, @opt_backing, @backers, $new_spec);
      GetOptions("backing=s@" => \@opt_backing, "profile=s" => \$opt_profile);
      Warn "$ARGV[0]: -backing flag conflicts with -profile\n"
	    if @opt_backing && $opt_profile;
      if (@opt_backing) {
	 @backers = split(/[,:\s]/, "@opt_backing");
	 map($_ = "Backing: $_\n", @backers);
	 $new_spec = <<EOCS;
element * CHECKEDOUT
#
#       Any modifications to the Profile config spec should
#       be made following this comment.      
# CC_PROJECT]

@backers
# [CC_PROJECT - Profile Config Spec
#       Do not directly modify the text below, it has been
#       automatically generated by the ClearCase::Ct module.
element * /main/0
EOCS
      } elsif ($opt_profile) {
	 # Need to grab the profile and (a) change all \ to /, and
	 # (b) remove ^M from the ends of the lines.
	 Die "no profile storage area defined\n" if ! defined $ProfileStgRoot;
	 my $ru = "$ProfileStgRoot/$opt_profile/Rules";
	 Die "$ru: $!\n" unless open(FH_RULE, $ru);
	 for my $line (<FH_RULE>) {
	    substr($line, -2) = "\n";	# remove the MS carriage return
	    $line =~ s%\\%/%g;		# change \ to / globally
	    $new_spec .= $line;
	 }
	 close(FH_RULE);
	 $new_spec .= "##:Profile: $opt_profile\n";
      }

      TEMP_ARGV: {
	 local(@ARGV) = @ARGV;	# operate on temp argv
	 StripOptions(\@ARGV, "tcomment|tmode|region|ln|host|hpath|gpath=s",
		    "ncaexported", "cachesize=s",
	 );
	 GetOptions("tag=s" => \$opt_tag);
	 if ($opt_tag && ($#ARGV == 0) && defined $ViewStgRoot) {
	    $stg = "$ViewStgRoot/$ENV{LOGNAME}/$opt_tag.vws";
	 }
      }
      push(@ARGV, $stg) if $stg;
      if ($opt_tag) {
	 if ($ENV{LOGNAME} !~ /^$VobAdm/) {
	    # Policy: personal views (workspaces) should be prefixed by name
	    Warn "personal view names should match $ENV{LOGNAME}_*\n"
		  if ($opt_tag !~ /^$ENV{LOGNAME}_/);

	    # Policy: view-storage areas should be in std place.
	    if (defined $ViewStgRoot) {
	       $stg = "$ViewStgRoot/$ENV{LOGNAME}/$opt_tag.vws";
	       if ($ARGV[-1] =~ m%$stg$%) {
		  my($vwbase) = ($ARGV[-1] =~ m%(.+)/[^/]+\.vws$%);
		  mkpath($vwbase, 0, 0755) unless -d $vwbase;
	       } else {
		  Warn "standard view storage is $stg\n";
	       }
	    }
	 }
      }

      # Only workspaces get the config-spec initialization treatment below;
      # for other views we stay out of the way.
      last COMMAND unless $opt_tag =~ /^$ENV{LOGNAME}_/;

      # Initialize a new config spec with the appropriate boilerplate.
      # This needs to be done in a post-op action since the mkview
      # command offers no interface to specify an initial config spec.
      if ($new_spec) {
	 push(@::PostOpEvalStack, '_mkview_post() unless $::Retcode');
	 sub _mkview_post {
	    return $::Retcode if $::Retcode;
	    my $tag = ViewTag() || return 0;
	    my $cstmp = "$TmpDir/mkview.cs.$tag";
	    open(FH_CSTMP, ">$cstmp") || return 0;
	    print FH_CSTMP $new_spec;
	    close(FH_CSTMP) || return 0;
	    unlink($cstmp) unless System($0, 'setcs', '-tag', $tag, $cstmp);
	 };
      }

      last COMMAND;
   }

=item * SYNCCS

New command: takes an optional view tag via B<-tag> and a view-profile
name with B<-profile>, and synchronizes the config spec with the
profile.  If no tag is passed, operates on the current view spec; if no
B<-profile>, re-synchronizes with the current profile.

=cut

   if (/^synccs$/) {
      my $profile;
      GetOptions("profile=s" => \$profile);
      my $tag = ViewTag();
      die $Help{$_} unless $tag;
      $vws ||= ViewStorage($tag) or die;
      $spec ||= "$vws/config_spec";
      my($line, $rdata, $sdata);

      # Open the config spec, read its lines into an array, close it.
      # If the view profile wasn't specified, try to find the current
      # association as a conventional comment in the cspec.
      Die "$spec: $!\n" unless open(FH_SPEC, $spec);
      for $line (<FH_SPEC>) {
	 if ($line =~ /^##:Profile:\s*(.*)/) {
	    $profile ||= $1;
	 } else {
	    $sdata .= $line;
	 }
      }
      close(FH_SPEC);

      # Open the rule profile, read its lines into an array, close it.
      Die "no profile specified or found\n" unless $profile;
      Die "no profile storage area defined\n" if ! defined $ProfileStgRoot;
      my $rule = "$ProfileStgRoot/$profile/Rules";
      Die "$rule: $!\n" unless open(FH_RULE, $rule);
      for $line (<FH_RULE>) {
	 substr($line, -2) = "\n";	# strip the DOS \r
	 $line =~ s%\\%/%g;		# change \ to / globally
	 $rdata .= $line;
      }
      close(FH_RULE);

      # Break the config-spec and rule arrays up by the conventional
      # view-profile tokens, and replace the old boilerplate parts with
      # the new versions.
      my @spec_arr = split(/^(.*CC_PROJECT.*)$/m, $sdata);
      my @rule_arr = split(/^(.*CC_PROJECT.*)$/m, $rdata);
      $spec_arr[2] = $rule_arr[2];
      $spec_arr[6] = $rule_arr[6];

      # Remember the currently-associated profile.
      push(@spec_arr, "##:Profile: $profile\n");

      # Now build a temp file from the appropriate sections of the
      # old config spec and the new rule profile, and use setcs to
      # make it the new config spec.
      my $cstmp = "$TmpDir/synccs.cs.$tag";
      die "$cstmp: $!" unless open(FH_CSTMP, ">$cstmp");
      print FH_CSTMP @spec_arr;
      close(FH_CSTMP);
      
      # Run the setcs, remove the temp file, done.
      unlink($cstmp) unless System($0, 'setcs', '-tag', $tag, $cstmp);
      exit;
   }

=item * UNCO

Modified default to always use -rm (this may be controversial but is
easily overridden in the user's profile).

Extended to accept (and ignore) the B<-nc> flag for consistency with
other cleartool cmds.

Extended to handle the -dir/-rec/-all flags.

=cut

   if (/^unc/) {
      # Extension: allow and ignore comment flags for consistency.
      StripOptions(\@ARGV, "cqe|nc", "c|cfile=s");

      # Change default: always use -rm to 'unco'.
      splice(@ARGV, 1, 0, '-rm') unless grep /^-rm$|^-kee/, @ARGV;

      # Extension: handle AutoOpt flags (parsed above).
      push(@ARGV, CheckedOutList(\@ARGV, "keep|rm|cwork")) if (keys %AutoOpt);

      # Similar to checkin/checkout hack.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      last COMMAND;
   }

=item * SETVIEW/STARTVIEW/ENDVIEW

Extended to support the B<-me> flag (prepends E<lt>B<username>E<gt>_* to tag).

=cut

   if (/^setview$|^startview$|^endview$/) {
      my($opt_setview_me);
      GetOptions("me" => \$opt_setview_me);
      $ARGV[-1] = join('_', $ENV{LOGNAME}, $ARGV[-1])
	    if ($opt_setview_me && $ARGV[-1] !~ /^$ENV{LOGNAME}/);
      last COMMAND;
   }

}

###################### End of Command Section ##########################

# Always return explicit truth at the end of require'd files.
1;

__END__

=back

=head1 FURTHER CUSTOMIZATION

Working on a profile is actually quite easy if you remember that within
it B<$_> is set to the command name, B<@ARGV> is the complete command
line and B<@_> is a copy of it, B<$0> is the path to the wrapper, and
B<$ClearCmd> is the path to the real I<cleartool> program.  Also, the
hash B<%Vgra> is a reverse lookup such that C<I<$ARGV[$Vgra{xyz}] eq "xyz">>.

With most perl modules, the C<.pm> code itself (the part that gets
found via C<@INC>) is static - it's not generally modified except via
updates of the module. Meanwhile, users write code to use the module
and that code is fluid; they change it as they please.  This module is
backwards from that since the B<ct> program is policy-free and thus
shouldn't need to be changed significantly.  Meanwhile, the
B<Profile.pm> is intended to be a reflection of the local policies and
preferences; the provided B<Profile.pm> is simply a sample of what
can be done.

The B<Profile.pm> does B<not> establish a separate namespace; it operates
within C<main::>. There did not seem to be any good reason to do so,
since the whole point is to operate directly on the namespace provided
by the client program B<ct>.

The B<ct> program is normally expected to be used under that name,
which means that users running B<cleartool lsco>, for instance, will go
around the wrapper.  However, it's also designed to allow for complete
wrapping if desired. To do so, move C<$ATRIAHOME/bin/cleartool> to
C<$ATRIAHOME/bin/wrapped/cleartool> and install B<ct> as
C<$ATRIAHOME/bin/cleartool>. You can continue to install/link the wrapper
as B<ct> as well - it won't invoke the wrapper twice because it
contains code to detect the presence of the moved-aside binary and run
it.

As a safety mechanism, the C<require>-ing of the profile is handled
within an C<eval> block, so a syntax error or config problem in the
profile won't cause it to fail.  It will simply print a warning and
continue.

=head1 AUTHOR

David Boyce, dsb@world.std.com

=head1 SEE ALSO

cleartool(1), perl(1).

=cut
