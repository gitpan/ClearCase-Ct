#!/usr/local/bin/perl	# for doc purposes only, not executable as is

# Note: the version # below may move independently of the one in Ct.pm.

=head1 NAME

Profile.pm - site-wide customizations for I<ct> wrapper

=head1 VERSION

1.17

=head1 SYNOPSIS

This perl module functions as a
wrapper for B<cleartool>, allowing the command-line interface of
B<cleartool> to be extended or modified. It allows defaults to be
changed, new flags to be added to existing B<cleartool> commands, or
entirely new B<cleartool> commands to be synthesized.

Unfortunately, there's no equivalent mechanism for wrapping GUI access
to clearcase.

=head1 SUMMARY

Here's a quick overview of the extensions available via B<I<ct>> which
may be of interest to users:

Many I<cleartool> commands have been enhanced to simulate the standard
flags B<-dir>, B<-rec>, B<-all>, and B<-avobs> which cause the command
to operate on (respectively) all eligible elements in the current dir,
the current dir recursively, the current vob, and all vobs. The
enhanced commands include B<checkin/ci>, B<unco>, B<diff>, B<mkelem>,
and B<lsprivate>.  Thus you could check in all checkouts in the current
view with B<I<ct ci -avobs>> or see the view-private files in and under
the current dir with B<I<ct lsprivate -rec>>. You can convert a tree of
view-private data into elements with B<I<ct mkelem -rec -ci>>.

The B<I<ct checkin>> command is also enhanced to take a B<-diff> flag which
prints your changes to the screen before prompting for a comment.

A new command B<I<ct edit>> is added. This is the same as B<I<ct checkout>>
but execs your favorite editor after checking out. It also takes a
B<-ci> flag which will check the file in afterwards.

All commands which take a B<-tag I<view-tag>> option are enhanced to
recognize the B<-me> flag.  This modifies the effect of B<-tag> by
prepending your username to the view name. E.g.  B<-tag I<foo> -me> is a
shorthand for B<-tag I<E<lt>usernameE<gt>_foo>>.  Similarly,
B<I<ct lsview -me>> will show only views whose names match the pattern
I<E<lt>B<username>E<gt>_*>.

The B<I<ct mkview>> command is enhanced to default the view-storage
location to a standard place using a standard naming convention.  See
I<SiteProfile.pm.sample> for how this is set up.  Also, B<mkview>
recognizes the B<-me> flag as described above. This means that making a
new view can/should be done as B<I<ct mkview -tag foo -me>>.

New pseudo-commands B<I<ct edattr>> and B<I<ct edcmnt>> are added. These
make it easy to edit the attributes and comments, respectively, of
a particular version.

A new command B<I<ct rmpriv>> is added, which behaves like
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
# pseudo-command can print them on error. The keys below must be the
# real name of the cmd, not an abbreviation.
{

   $Help{catcs} .= "
           * [-cmnt|-expand|-rdl|-sources|-start]";

   $Help{checkin} .= "
                  * [-dir|-rec|-all|-avobs] [-iff] [-diff [diff-opts]] [-revert]";

   $Help{checkout} .= "
                   * [-dir|-rec|-all]";

   $Help{diff} .= "
          * [-c] [-dir|-rec|-all|-avobs]";

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

   $Help{mkview} =~ s/  (view-storage-pname)/* [-me] [-local] [-clone <view>]
            * [$1]/;

   $Help{setcs} .= "
           * [-sync]";

   $Help{setview} .= " * [-me] [-drive drive:] [-persistent]";

   $Help{uncheckout} .= "
                       * [-nc]";

   $Help{synccs} .= "Usage: *synccs [-tag view-tag] -profile profile-name";

   $Help{eclipse} .= "Usage: *eclipse element ...";

   $Help{edattr} .= "Usage: *edattr object-selector ...";

   $Help{edcmnt} .= "Usage: *edcmnt [-new] object-selector ...";

   $Help{grep} .= "Usage: *grep [grep-flags] pattern element";

   $Help{workon} = "* Usage: workon [-me] [-login] [-exec command-invocation] view-tag\n";
}

###################### End of Help Section #############################

####################### Command Section ################################

use subs qw(Die Warn);	# keeps perl -c happy

# Just in case we need to do a 'mkdir -p' type of thing.
use autouse 'File::Path' => qw(mkpath);

# Just in case we need to copy a file ...
use autouse 'File::Copy' => qw(copy move);

# A list of users who are exempt from certain restrictions.
my @Admins = qw(vobadm ccall);

# Override the user's preferences while interacting with clearcase.
umask 002 if !grep(/^$ENV{LOGNAME}$/, @Admins);

# Similar to above but would withstand competition from settings in
# .kshrc et al. It's critical to build DO's with generous umasks
# in case they get winked in. We allow it to be overridden lower
# than 002 but not higher.
$ENV{CLEARCASE_BLD_UMASK} = 2
	if !defined($ENV{CLEARCASE_BLD_UMASK}) || $ENV{CLEARCASE_BLD_UMASK} > 2;

# Examines current ARGV, returns the specified or current view tag.
sub ViewTag
{
   my $vtag;
   local(@ARGV) = @ARGV;
   GetOptions("tag=s" => \$vtag);
   $vtag ||=  (split(m%[/\\]%, $ENV{CLEARCASE_ROOT}))[-1];
   $vtag ||= qx($CT pwv -s);
   chomp $vtag;
   return $vtag;
}

# Takes the name of a view tag, returns the storage dir for that view.
sub ViewStorage
{
   my($tag) = @_;
   my $vws;
   my @lsview = Qx($0, 'lsview', $tag);
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
	       |^diff$|^review$|^mkelem$|^lsp$|^lspri|^rmpriv/x
	    && grep /^-[dra]/, @ARGV) {
      StripOptions(\@ARGV, q(cview)) if grep /^-cvi/, @ARGV;
      GetOptions(\%AutoOpt, qw(directory recurse all avobs));
      if (keys %AutoOpt > 1) {
	 my @temp = join(' -', keys %AutoOpt);
	 die "conflicting flags:  -@temp\n";
      } elsif (keys %AutoOpt == 1) {

	 # Anonymous local sub to print out the set of elements we
	 # derived as 'eligible', whatever that means for that op.
	 my $showfound = sub {
	    my @fnd = @_;
	    if (@fnd == 0) {
	       warn "$ARGV[0]: no eligible elements found\n";
	       exit 0;
	    } elsif (@fnd <= 10) {
	       if ($Win32) { for (@fnd) { $_ = qq("$_") if /\s/ } }
	       warn "$ARGV[0]: found: @fnd\n";
	    } elsif (@fnd) {
	       if ($Win32) { for (@fnd[0..10]) { $_ = qq("$_") if /\s/ } }
	       my $i = @fnd - 4;
	       warn "$ARGV[0]: found: @fnd[0..3] [plus $i more] ...\n";
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
	    if ($AutoOpt{avobs}) {
	       @new_elems = Qx($0, qw(lsco -avobs), @t_argv);
	    } elsif ($AutoOpt{all}) {
	       @new_elems = Qx($0, qw(lsco -all), @t_argv);
	    } elsif ($AutoOpt{recurse}) {
	       @new_elems = Qx($0, qw(lsco -r), @t_argv);
	    } elsif ($AutoOpt{directory}) {
	       @new_elems = Qx($0, qw(lsco), @t_argv);
	    }
	    chomp @new_elems;
	    if ($Win32) { for (@new_elems) { $_ = qq("$_") if /\s/ } }
	    &$showfound(@new_elems);
	    return @new_elems;
	 }

	 # Return a list of non-checked-out files according to
	 # the -dir/-rec/-all flags. Ignores all arguments.
	 sub CheckedInList {
	    my @checkedin, %checkedout;

	    # Basically what we're doing below is using 'ct find' to
	    # derive the list of elements, then 'ct lsco' to find those
	    # already checked out, and subtract the 2nd list from the 1st
	    # (but there are subtle differences in each of the 3 cases).
	    # Done this way because there's no direct way to derive the
	    # list of elements _not_ checked out.
	    if ($AutoOpt{all}) {
	       %checkedout = map {$_, $_}
		  Qx($CT, qw(lsco -cview -s -all));
	       @checkedin = grep !$checkedout{$_},
		  Qx($CT, qw(find -all -type f -cvi -nxn -print));
	    } elsif ($AutoOpt{recurse}) {
	       %checkedout = map {s%^.[/\\]%%; $_, $_}
		  Qx($CT, qw(lsco -cview -s -r));
	       @checkedin = grep !$checkedout{$_},
		  map {s%^.[/\\]%%; $_}
		     Qx($CT, qw(find . -type f -cvi -nxn -print));
	    } elsif ($AutoOpt{directory}) {
	       %checkedout = map {$_, $_}
		  Qx($CT, qw(lsco -cview -s));
	       @checkedin = grep !$checkedout{$_},
		  grep !m%[/\\]%,
		     map {substr($_, 2)}
			Qx($CT, qw(find . -type f -cvi -nxn -print));
	    }
	    chomp @checkedin;
	    if ($Win32) { for (@checkedin) { $_ = qq("$_") if /\s/ } }
	    &$showfound(@checkedin);
	    return @checkedin;
	 }

	 sub PrivateList {
	    my @cmd = ($0, qw(lsp -s), @_);
	    if ($AutoOpt{all}) {
	       push(@cmd, '-all');
	    } elsif ($AutoOpt{recurse}) {
	       push(@cmd, '-rec');
	    } elsif ($AutoOpt{directory}) {
	       push(@cmd, '-dir');
	    }
	    my @new_elems = Qx(@cmd, '--reread');
	    chomp @new_elems;
	    #if ($Win32) { for (@new_elems) { $_ = qq("$_") if /\s/ && !/"/} }
	    &$showfound(@new_elems);
	    return @new_elems;
	 }

      }

      ## No 'last COMMAND' here; it's just an initializer block
   }

# Begin embedded pods

=over 4

=item * CATCS

=over 4

=item 1. New B<-expand> flag

Follows all include statements recursively in order to print a complete
config spec. The B<-cmnt> flag will strip comments from this listing.

=item 2. New B<-rdl> flag

Shows 'rdl' options embedded in the config spec.

=item 3. New B<-sources> flag

Prints the files involved in the config spec (the config_spec file
itself plus any include files).

=item 4. New B<-start> flag

Prints the I<initial working directory> of a view by examining its
config spec. If the conventional string C<##:Start: I<dir>> is present
then the value of I<dir> is printed. Otherwise no output is produced.

=back

=cut

##########################################################################
## The following are unlikely to be useful in most CC environments
## so are de-documented.
#Lots of enhancements here, mostly in the area of config-spec parsing
#for automation:
#
#=item 4. New B<-vobs> flag
#
#Prints a list of all vob tags referenced explicitly within the
#config spec.
##########################################################################

   if (/^catcs$/) {

      # Function to parse 'include' stmts recursively.  Used by
      # config-spec parsing meta-commands. The first arg is an
      # open filehandle, the second is a string which is eval-ed
      # for each line.  It can be as simple as 'print' or as
      # complex a regular expression as desired.
      ## Originally based on a sample function called process()
      ## given in perlfunc(1).
      sub burrow {
	 local $input = shift;
	 my($filename, $action) = @_;
	 print $filename, "\n" if !$action;
	 $input++;
	 if (!open($input, $filename)) {
	    warn "$filename: $!";
	    return;
	 }
	 while (<$input>) {
	    if (/^include\s+(.*)/) {
		burrow($input, $1, $action);
		next;
	    }
	    eval $action if $action;
	 }
      }

      my(%opt, $op);
      GetOptions(\%opt, qw(cmnt expand rdl start|iwd sources vobs));
      if ($opt{sources}) {
	 $op = '';
      } elsif ($opt{expand}) {
	 $op = 'print';;
      } elsif ($opt{rdl}) {
	 $op = 's%##:RDL:\s*(.+)%print "$+\n";exit 0%ie';
      } elsif ($opt{start}) {
	 $op = 's%##:Start:\s+(\S+)|^\s*element\s+(\S*)/\.{3}\s%print "$+\n";exit 0%ie';
      } elsif ($opt{vobs}) {
	 $op = 's%^element\s+(\S+)/\.{3}\s%print "$1\n"%e';
      }
      if (defined $op) {
	 $op .= ' unless /^\s*#/' if $op && $opt{cmnt};
	 my $tag = ViewTag();
	 die "Error: no view tag specified or implicit" if !$tag;;
	 my($cs) = reverse split '\s+', qx($CT lsview $tag);
	 exit burrow('CATCS_00', "$cs/config_spec", $op);
      }
      # A vanilla catcs cmd will fall out here and run the regular way
      last COMMAND;
   }

=item * SETCS

Adds a B<-sync> flag. This is similar to B<-current> except that it
analyzes the view dependencies and only flushes the view cache if the
compiled_spec is out of date with respect to the config_spec source
file or a file it includes.

=cut

   if (/^setcs$/) {
      my %opt;
      GetOptions(\%opt, qw(sync));
      if ($opt{sync}) {
	 my $tag = ViewTag();
	 chomp(my @srcs = qx($0 catcs --reread --sources -tag $tag));
	 exit 2 if $?;
	 (my $obj = $srcs[0]) =~ s/config_spec/.compiled_spec/;
	 die "$obj: no such file" if ! -f $obj;
	 die "Error: no permission to update $tag's config spec\n" if ! -w $obj;
	 my $otime = (stat $obj)[9];
	 for (@srcs) {
	    Exec($CT, qw(setcs -current -tag), $tag) if (stat $_)[9] > $otime;
	 }
	 exit 1;
      }
      last COMMAND;
   }

=item * CI/CHECKIN

Extended to handle the B<-dir/-rec/-all> flags.

Extended to allow symbolic links to be "checked in" (by simply
checking in the target of the link instead).

Extended to implement a B<-diff> flag, which runs a B<I<ct diff -pred>>
command before each checkin so the user can look at his/her changes
before typing the comment.

Also, automatically supplies C<-nc> to checkins if the element list
consists of only directories (directories get a default comment).

Implements a new B<-revert> flag. This causes identical (unchanged)
elements to be unchecked-out instead of being checked in.

Also extended to implement a B<-iff> flag. This reduces the supplied list
of elements to those truly checked out. E.g. C<ct ct -iff *.c> will check
in only the elements which match *.c B<and> are checked out, without
producing a lot of errors for the others.

=cut

   if (/^ci$|^checkin$/) {
      my @ci_flags = qw(c|cfile=s cqe|nc 
			nwarn|cr|ptime|identical|rm from=s 
			diff|graphical|tiny|hstack|vstack|predecessor 
			serial_format|diff_format|window 
			columns|options=s);

      if (keys %AutoOpt) {
	 # Extension: handle AutoOpt flags (parsed above).
	 push(@ARGV, CheckedOutList(\@ARGV, @ci_flags, qw(revert)));
      } else {
	 # Or: automatically glob explicit args (on Windows).
	 @ARGV = DosGlob(\@ARGV, @ci_flags) if $Win32;
      }

      # If the user tries to check in a symlink, replace it with
      # the path to the actual element. Same at checkout time.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      # Default to -nc if checking in directories.
      if (!grep(/^-c$|^-cq|^-nc$|^-cfi/, @ARGV)) {
	 my $alldirs = 1;
	 my @args = @ARGV;
	 shift @args;
	 for (RemainingOptions(\@args, qw(
		  cqe|nc|nwarn|cr|ptime|identical|rm c|cfile|from=s
		  serial_format|diff_format|window context
		  graphical|tiny|hstack|vstack|predecessor options=s))) {
	    $alldirs = 0 if ! -d;
	 }
	 splice(@ARGV, 1, 0, '-nc') if $alldirs;
      }

      my($opt_ci_diff, $opt_ci_revert, $opt_ci_iff);
      {
	 local $Getopt::Long::autoabbrev = 0; # don't mistake -ide for -iff!
	 GetOptions("diff" => \$opt_ci_diff, "revert" => \$opt_ci_revert,
		     "iff" => \$opt_ci_iff);
      }

      # Extension: -iff flag trims @ARGV to those really checked out.
      if ($opt_ci_iff) {
	 my @elems = RemainingOptions(\@ARGV,
		     qw(cqe|nc|nwarn|cr|ptime|identical|rm c|cfile|from=s
			serial_format|diff_format|window context
			graphical|tiny|hstack|vstack|predecessor options=s));
	 shift @elems;
	 my $flag_cnt = @ARGV - @elems;
	 my @selected = `$CT lsco -s @elems 2>$DevNull`;
	 if (!@selected) {
	    `$CT lsco -s @elems`; # just to repeat the error msg.
	    warn "no elements selected\n" unless $?;
	    exit $?>>8;
	 }
	 chomp @selected;
	 splice(@ARGV, $flag_cnt, @elems, @selected);
      }

      # Extension: -d/iff flag runs 'cleartool diff' on each elem first
      if ($opt_ci_diff || $opt_ci_revert) {
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
		     "serial_format|diff_format|window", "context",
		     "graphical|tiny|hstack|vstack|predecessor", "options=s");
	    my $start = @ARGV - @elems;
	    # The part of the argv before the element list must be diff-flags.
	    @diff_args = @ARGV[0..$start-1] || qw(-serial);
	 }
	 # Strip diff options from argv since we've captured them elsewhere.
	 StripOptions(\@ARGV, "serial_format|diff_format|window",
		  "graphical|tiny|hstack|vstack|predecessor", "options=s");
	 # Strip element list since we have it - what remains is checkin opts.
	 splice(@ARGV, @ARGV - @elems);
	 if (@elems) {
	    for $elem (@elems) {
	       # If -revert and no changes, uncheckout instead of checkin
	       my $chng;
	       if ($opt_ci_diff) {
		  $chng = System($0, qw(diff -pred), @diff_args, $elem);
	       } else {
		  $chng = System($0, qw(diff -pred), $elem, '>/dev/null');
	       }
	       if ($opt_ci_revert && !$chng) {
		  System($CT, qw(unco -rm), $elem);
	       } else {
		  splice(@ARGV, 1, 0, '-cqe') if !grep /^-c|^-nc$/, @ARGV;
		  System($CT, @ARGV, $elem);
	       }
	    }
	    # All done, no need to return to wrapper program.
	    exit $?>>8;
	 }
      }
      last COMMAND;
   }

=item * CO/CHECKOUT

Extension: if element being checked out is a symbolic link, silently
replace it with the name of its target, because for some reason
ClearCase doesn't do this automatically.

Automatically defaults checkouts to use -nc. This could be done with
clearcase_profile as well, of course, but is more centralized here.

=item * EDIT

Convenience command. Same as 'checkout' but execs your favorite editor
afterwards. Takes all the same flags as checkout, plus B<-ci> to check
the element back in afterwards. When B<-ci> is used in conjunction with
B<-diff> the file will be either checked in or un-checked out depending
on whether it was modified.

Also, B<I<ct edit -dir>> will not check anything out but will exec the
editor on all currently checked-out files.

=cut

   if (/^co$|^checkout$|^edit$/) {
      # Do the user a favor and handle globbing for DOS shell.
      @ARGV = DosGlob(\@ARGV) if $Win32;

      # If the user tries to check out a symlink, replace it with
      # the path to the actual element. Don't know why CC doesn't
      # do this or at least provide a -L flag.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      # Implement -dir/-rec/-all.
      push(@ARGV, CheckedInList(\@ARGV, qw(out|branch=s c|cfile=s cqe|nc
			   reserved|unreserved|ndata|version|nwarn)))
	 if (keys %AutoOpt);

      if (/^co$|^checkout$/) {
	 splice(@ARGV, 1, 0, '-nc') if !grep(/^-c$|^-cq|^-nc$|^-cfi/, @ARGV);
      } elsif (/^edit$/) {
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
	 if (System($CT, qw(co -nc), @ARGV[1..$#ARGV])) {
	    exit $?>>8 if Prompt(qw(yes_no -mask y,n -pro), 'Continue?');
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
      my %Opt;
      my(@elems);
      my @diff_flags = ("serial_format|diff_format|window",
			"graphical|tiny|hstack|vstack|predecessor",
			"options=s");

      {
	 local $Getopt::Long::autoabbrev = 0;
	 GetOptions(\%Opt, 'context|c', 't=s');
      }

      # Similar to checkin/checkout hack.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      if (/^review$/) {
	 $Opt{context} = 1;
	 $Opt{t} ||= 'Code Review';
      }

      if (keys %AutoOpt) {
	 @elems = CheckedOutList(\@ARGV, @diff_flags);
      } else {
	 @elems = RemainingOptions(\@ARGV,  @diff_flags);
	 shift @elems;
      }

      if ($Opt{context}) {
	 my $finalstat = 0;
	 for my $elem (@elems) {
	    my $pred = qx($CT desc -short -pred $elem);
	    chomp $pred;
	    if (/^review$/) {
	       open(STDOUT, "| pprint -t '$elem'") || Warn "$!";
	    }
	    $elem =~ s/^"(.*)"$/$1/;
	    $pred = "$elem\@\@$pred";
	    my $rc = System('/usr/bin/diff', '-c', $pred, $elem);
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
      splice(@ARGV, 1, 0, '-serial') if !grep(/^-(?:ser|dif|col|g)/, @ARGV);
      splice(@ARGV, 1, 0, '-pred') if !grep(/^-pre/, @ARGV) && @elems < 2;
      last COMMAND;
   }

=item * ECLIPSE

New command. I<Eclipse>s an element by copying a view-private version
over it. This is the dynamic-view equivalent of "hijacking" a file in a
snapshot view. Typically of use if you need temporary write access to a
file when the VOB is locked, or it's checked out reserved.  B<Eclipsing
elements can lead to dangerous levels of confusion - use with care!>

=cut

   if (/^eclipse$/) {
      Die "$Help{$_}\n" unless @ARGV > 1;
      my $retstat = 0;
      shift @ARGV;
      my @orig = Qx($CT, catcs);
      for my $elem (@ARGV) {
	 if (! -f $elem || -w _) {
	    Warn "don't know how to eclipse '$elem'\n";
	    $retstat++;
	    next;
	 }
	 my $cstmp = "$TmpDir/cstmp.$$";
	 open(CSTMP, ">$cstmp") || die "$cstmp: $!";
	 print CSTMP "element $elem -none\n";
	 print CSTMP @orig;
	 close(CSTMP) || die "$cstmp: $!";
	 if (!copy($elem, "$elem.eclipse.$$")) {
	    Warn "$elem: $!\n";
	    $retstat++;
	    next;
	 }
	 if (System($CT, qw(setcs), $cstmp)) {
	    $retstat++;
	    next;
	 }
	 if (!move("$elem.eclipse.$$", $elem)) {
	    Warn "$elem: $!\n";
	    $retstat++;
	    next;
	 }
	 open(CSTMP, ">$cstmp") || die "$cstmp: $!";
	 print CSTMP @orig;
	 close(CSTMP) || die "$cstmp: $!";
	 if (System($CT, qw(setcs), $cstmp)) {
	    Warn "your config spec may be broken!!";
	    exit 2;
	 }
	 unlink $cstmp;
      }
      exit $retstat;
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
      shift @ARGV;
      Die "$Help{$_}\n" unless @ARGV;
      my $retstat = 0;
      for my $elem (@ARGV) {
	 my %indata = ();
	 #$elem .= '@@' unless $elem =~ /\@\@/;
	 my @lines = qx($CT desc -aattr -all $elem);
	 if ($?) {
	    $retstat++;
	    next;
	 }
	 for my $line (@lines) {
	    next unless $line =~ /\s*(\S+)\s+=\s+(.+)/;
	    $indata{$1} = $2;
	 }
	 my $edtmp = "$TmpDir/edattr.$$";
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
	       my($attr, $newval) = ($1, $2);
	       my $oldval;
	       if (defined($oldval = $indata{$attr})) {
		  delete $indata{$attr};
		  # Skip if data unchanged.
		  next if $oldval eq $newval;
	       }
	       # Figure out what type the new attype needs to be.
	       # Sorry, didn't bother with -vtype time.
	       if (System("$CT lstype attype:$attr >$DevNull 2>&1")) {
		  if ($newval =~ /^".*"$/) {
		     System($CT, qw(mkattype -nc -vty string), $attr);
		  } elsif ($newval =~ /^[+-]?\d+$/) {
		     System($CT, qw(mkattype -nc -vty integer), $attr);
		  } elsif ($newval =~ /^-?\d+\.?\d*$/) {
		     System($CT, qw(mkattype -nc -vty real), $attr);
		  } else {
		     System($CT, qw(mkattype -nc -vty opaque), $attr);
		  }
	       }
	       # Hack to make string-typed attrs work on ^%@# Windows.
	       $newval = "\\\"$newval\\\"" if $Win32 && $newval =~ /^".*"$/;
	       if (defined($oldval)) {
		  my $cmnt = $Win32 ? qq("(Was: $oldval)") : "(Was: $oldval)";
		  $retstat++ if System($CT, qw(mkattr -rep -c),
				 $cmnt, $attr, $newval, $elem);
	       } else {
		  $retstat++ if System($CT, qw(mkattr -rep),
				 $attr, $newval, $elem);
	       }
	    } else {
	       $retstat++;
	       Warn "edattr: incorrect line format: '$_'";
	    }
	 }
	 close(EDTMP) || die "$edtmp: $!";
	 unlink $edtmp;

	 # Now, delete any attrs that were deleted from the temp file.
	 # First we do a simple rmattr; then see if it was the last of
	 # its type and if so remove the type too.
	 for (sort keys %indata) {
	    if (System($CT, 'rmattr', $_, $elem)) {
	       $retstat++;
	    } else {
	       # Don't remove the type if its vob serves as an admin vob!
	       my(@deps) = grep /^<-/, `$CT desc -s -ahl AdminVOB vob:.`;
	       System($CT, 'rmtype', '-rmall', "attype:$_")
		  if $? == 0 && ! @deps;
	    }
	 }
      }
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
      shift @ARGV;
      Die "$Help{$_}\n" unless @ARGV;
      my $retstat = 0;
      # Checksum before and after edit - only update if changed.
      my($csum_pre, $csum_post);
      for my $elem (@ARGV) {
	 my @input = ();
	 if (!$opt_edcmnt_new) {
	    @input = Qx($CT, qw(desc -fmt %c), $elem);
	    next if $?;
	 }
	 my $edtmp = "$TmpDir/edcmnt.$$";
	 open(EDTMP, ">$edtmp") || Die "$edtmp: $!";
	 for (@input) {
	    next if /^~\w$/;  # Hack - allow ~ escapes in ci-trigger a la mailx
	    $csum_pre += unpack("%16C*", $_);
	    print EDTMP $_;
	 }
	 close(EDTMP) || Die "$edtmp: $!";
	 System($Editor, $edtmp) || 1;  ## ignore $? - vi sometimes exits >0
	 open(EDTMP, $edtmp) || Die "$edtmp: $!";
	 while (<EDTMP>) { $csum_post += unpack("%16C*", $_); }
	 close(EDTMP) || Die "$edtmp: $!";
	 next if $csum_post == $csum_pre;
	 if (System($CT, qw(chevent -replace -cfi), $edtmp, $elem)) {
	    $retstat++;
	    next;
	 }
	 unlink $edtmp;
      }
      exit $retstat;
   }

=item * RMPRIV

New convenience command. Conceptually this is just a shorthand for
B<"rm -i `ct lsp`">, but it also handles convenience features such as the
rm-like B<-f> flag plus B<-dir/-rec/-all>.  It also has the benefit of
behaving the same way on NT, which rm doesn't.

=cut

   if (/^rmpriv/) {
      Die "$ARGV[0]: must use one of -dir/-rec/-all\n" unless keys %AutoOpt;
      GetOptions("i" => \$opt_i, "f" => \$opt_f);
      for my $inode (reverse PrivateList(qw(-other -do))) {
	 if ($opt_i || ! $opt_f) {
	    next if Prompt(qw(yes_no -mask y,n -def n -pro),
				 "$ARGV[0]: remove '$inode'? ");
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
	 Exec("$CT @ARGV -print |
	       /usr/bin/xargs $CT desc -fmt '$opt_fmt'");
      }
      last COMMAND;
   }

=item * GREP

New command. Greps all past revisions of a file for a pattern, so you
see which revision introduced a particular function or which introduced
a particular bug.  Suggested by Seth Alford <setha@plaza.ds.adp.com>.

=cut

   if (/^grep$/) {
      my $file = pop(@ARGV);
      chomp(my @versions = sort {($b =~ m%/(\d+)%)[0] <=> ($a =~ m%/(\d+)%)[0]}
				    map { s/@@.*CHECKEDOUT$//; $_ }
				    Qx($CT, qw(lsvt -a -s), $file));
      Exec(@ARGV, @versions);
      exit 0;
   }

=item * LS

On Windows, do the user a favor and handle globbing for DOS shell.

=cut

   if (/^ls$/) {
      @ARGV = DosGlob(\@ARGV) if $Win32;
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
behaves in a B<-avobs> fashion). Also allows a directory to be
specified, such that 'ct lsprivate .' restricts output to cwd.

=cut

   # make sure we don't catch 'lsproject' here ...
   if (/^lsp$|^lspri/) {
      # Extension: allow [dir] argument
      if (RemainingOptions(\@ARGV, "co|do|other|short|long",
					     "tag|invob=s") == 2) {
	 $AutoOpt{place} = pop(@ARGV);
	 # Default to -rec but accept -dir.
	 $AutoOpt{recurse} = !$AutoOpt{directory} if !$AutoOpt{all};
      }

      # Extension: allow [-dir|-rec]
      if ($AutoOpt{recurse} || $AutoOpt{directory}) {
	 my($dir, $tag);
	 chomp($dir = Cwd::abs_path($AutoOpt{place} || '.'));
	 if ($Win32) {
	     $dir =~ s/^[A-Z]://i;
	     $dir =~ s%\\%/%g;
	 }
	 GetOptions('tag=s' => \$tag);
	 if ($dir =~ s%/+view/([^/]+)%%) {
	    $tag ||= $1;
	 } elsif (!$tag) {
	    chomp($tag = `$CT pwv -s`);
	 }
	 chomp(my @privs = sort `$CT @ARGV -tag $tag`);
	 for (@privs) { s/^[A-Z]://i; s%\\%/%g; s%(/+view)?/$tag%% }
	 if ($AutoOpt{recurse}) {
	    print map {"$_\n"}
		  map {$_ || '.'}
		  map {m%^$dir/(.*)%} 
		  map {$_ eq $dir ? "$_/" : $_} @privs;
	 } elsif ($AutoOpt{directory}) {
	    print map {"$_\n"}
		  map {$_ || '.'}
		  map {m%^$dir/([^/]*)$%s}
		  map {$_ eq $dir ? "$_/" : $_} @privs;
	 }
	 exit;
      } elsif ($AutoOpt{all}) {
	 splice(@ARGV, 1, 0, '-invob', $AutoOpt{place} || '.');
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
global type in the admin VOB instead. B<I<In effect, this makes -global
the default iff a suitable admin VOB exists>>.

=item * MKBRTYPE,MKLBTYPE

Same as mkattype above.

=cut

   if (/^(mkattype|mkbrtype|mklbtype)$/) {
      if (! grep(/^-ord|^-glo|vob:/i, @ARGV)) {
	 if (my(@adms) = grep /^->/, `$CT desc -s -ahl AdminVOB vob:.`) {
	    if (my $adm = (split(' ', $adms[0]))[1]) {
	       chomp $adm;
	       warn "Making global type in $adm ...\n";
	       # Save aside all possible flags for mkattype/mklbtype,
	       # then add the vob selector to each type selector,
	       # and put the flags back along with the new -global.
	       my @flags = StripOptions(\@ARGV, "replace|global|ordinary",
			      "vpelement|vpbranch|vpversion",
			      "gt|ge|lt|le|enum|default|vtype=s",
			      "pbranch|shared",
			      "cqe|nc", "c|cfile=s");
	       for (@ARGV[1..$#ARGV]) {$_ .= "\@$adm"}
	       splice(@ARGV, 1, 0, @flags, '-global');
	    }
	 }
      }
   }

=item * MKELEM

Extended to handle the B<-dir/-rec> flags, enabling automated mkelems
with otherwise the same syntax as original. Directories are also
automatically checked out as required in this mode. B<Note that this
automatic directory checkout is only enabled when the candidate list is
derived via the C<-dir/-rec> flags>.  If the B<-ci> flag is present,
any directories automatically checked out are checked back in too.

=cut

   if (/^mkelem$/) {
      # Extension: handle AutoOpt flags (parsed above).
      last COMMAND unless keys %AutoOpt;
      Die "flag not supported for command '$_'\n"
	    if $AutoOpt{all};

      # Derive the list of view-private files to work on.
      # Some files we don't ever want to put under version control...
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
	 next if ! $d || $dirs{$d};
	 my $lsd = qx($CT ls -d "$d");
	 # If no version selector given, it's a view-private dir and
	 # will be handled below.
	 next unless $lsd =~ /\sRule:\s/;
	 # If already checked out, nothing to do.
	 next if $lsd =~ /CHECKEDOUT$/;
	 # Now we know it's an element and needs to be checked out.
	 $dirs{$d}++;
      }

      # Now mkelem the dirs. God I hate Windows.
      if ($Win32) {
	 for (keys %dirs) {
	    exit $?>>8 if System($CT, qw(co -nc), qq("$_"));
	 }
      } else {
	 exit $?>>8 if keys %dirs && System($CT, qw(co -nc), keys %dirs);
      }

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
	 if ($Win32) {
	    if(System($CT, qw(mkdir -nc), qq("$cand"))) {
	       rename($tmpdir, $cand);
	       exit 2;
	    }
	 } else {
	    if(System($CT, qw(mkdir -nc), $cand)) {
	       rename($tmpdir, $cand);
	       exit 2;
	    }
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

      # Now we've made all the directories - do the files in one fell
      # swoop. Except on *&#@ Windows where we must do them one at a
      # time for quoting reasons.
      if ($Win32) {
	 local(@ARGV) = @ARGV[1..$#ARGV];  # operate on temp argv
	 my @flags = StripOptions(\@ARGV,
	       "eltype=s", "nco|ci|ptime|master|nwarn", "cqe|nc", "c|cfile=s");
	 for (@ARGV) { System($CT, q(mkelem), @flags, qq("$_")); }
      } else {
	 System($CT, @ARGV) if @files;
      }

      # Now, if the -ci flag was supplied, check the dirs back in.
      my $opt_mkelem_ci;
      ReadOptions(\@ARGV, "ci" => \$opt_mkelem_ci);
      if ($opt_mkelem_ci && keys %dirs) {
	 # More weird *&#@ quoting for win32.
	 if ($Win32) {
	    my $ret;
	    for(keys %dirs) {
	       $ret ||= System($CT, qw(ci -nc), qq("$_"));
	    }
	    exit $ret>>8 if $ret;
	 } else {
	    exit $?>>8 if System($CT, qw(ci -nc), keys %dirs);
	 }
      }

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

=item 3. New I<-local> flag

By default, views are placed in a standard path on a standard
well-known view server.  Of course, the sophisticated user may specify
any view-storage location explicitly, taking responsibility for getting
the -host/-hpath/-gpath triple right. But a I<-local> flag is also
supported which will attempt to place the view in the same standard
place but on the local machine.

=item 4. New I<-clone> flag

This allows you to specify another view from which to copy the config
spec and other properties. Note that it does I<not> copy view-private
files from the old view, just the properties.

=back

=cut

   if (/^mkview$/) {
      # Policy: print warnings if new view's tag does not match the
      # local naming convention, or if the storage location is not
      # one of the approved areas.
      # Extension: if no view-storage area specified, use a standard one.
      my %opt;
      GetOptions(\%opt, qw(local clone=s));


      if (!grep(/^-sna/, @ARGV)) {
	 my $gstg;

	 # Site-specific preference for where we like to locate our views.
	 # If there's a local /*/vwstore area which is shared and automountable,
	 # put the view there. Otherwise require an explicit choice.
	 # This array holds (global local) storage path pairs.
	 my @vwsmap = qw(/data/ccase/vwstore/personal /data/ccase/vwstore/personal);
	 my $vhost = 'sparc5';
	 if ($opt{local}) {
	    warn "Warning: flag not implemented, no automounter in use";
=pod
	    require Sys::Hostname;
	    my $tmphost = Sys::Hostname::hostname();
	    @tmpmap = map {(split /[\s:]/)[0,2]}
		      grep {m%/$tmphost\s+$tmphost:.*/vwstore%}
		      qx(ypcat -k auto_dev);
	    if (!@tmpmap) {
	       warn "Warning: no /vws area on $tmphost, using $vwsmap[0]/...\n";
	    } else {
	       @vwsmap = @tmpmap[0,1];
	       $vhost = $tmphost;
	       if (@tmpmap > 2) {
		  my %vwdirs = @tmpmap;
		  warn "Warning: multiple storage areas (@{[keys %tmpmap]}) ",
					  "on $vhost, using $vwsmap[0]/...\n";
	       }
	       die "no such storage location: $vwsmap[0]\n" if ! -d $vwsmap[0];
	    }
=cut
	 }

	 {
	    local(@ARGV) = @ARGV;	# operate on temp argv
	    StripOptions(\@ARGV, qw(ncaexported|shareable_dos|nshareable_dos
		    tmode|region|ln|host|hpath|gpath|cachesize|stream=s)
	    );
	    GetOptions(\%opt, qw(tag=s tcomment=s));
	    last COMMAND if !$opt{tag};
	    if ($opt{tag} && ($#ARGV == 0) && @vwsmap) {
	       $gstg = "$vwsmap[0]/$ENV{LOGNAME}/$opt{tag}.vws";
	    }
	 }
	 splice(@ARGV, 1, 0, '-tco', "Created by $ENV{LOGNAME} on ".localtime)
							  if !$opt{tcomment};
	 if ($gstg) {
	     my $lstg = "$vwsmap[1]/$ENV{LOGNAME}/$opt{tag}.vws";
	     push(@ARGV, '-gpa', $gstg, '-hpa', $lstg, '-host', $vhost, $gstg);
	 }

	 if ($opt{tag}) {
	    # Policy: view-storage areas should be in std place.
	    if (@vwsmap) {
	       my $stgpat = "$ENV{LOGNAME}/$opt{tag}.vws";
	       if ($ARGV[-1] =~ m%$stgpat$%) {
		  my($vwbase) = ($ARGV[-1] =~ m%(.+)/[^/]+\.vws$%);
		  mkpath($vwbase, 0, 0755) unless -d $vwbase;
	       } else {
		  Warn "standard view storage path is /vws/.../$stgpat\n";
	       }
	    }
	 }
      }

      # Policy: personal views should be prefixed by username.
      Warn "view names should match $ENV{LOGNAME}_*\n"
	    if !grep(/^$ENV{LOGNAME}$/, @Admins) &&
		     $opt{tag} !~ /^$ENV{LOGNAME}_/;

      # If an option was used requiring a special config spec, make the
      # view here, then change the spec, then exit. Must be done this way
      # because mkview provides no way to specify the initial config spec.
      # Also clone other properties such as cachesize and text mode.
      if ($opt{clone}) {
	 chomp(my @data = qx($CT lsview -prop -full $opt{clone}));
	 my %lsview = map {(split /:\s*/)[0,1]} @data;
	 splice(@ARGV, 1, 0, '-tmode', $lsview{'Text mode'})
						   if $lsview{'Text mode'};
	 my %properties = map {$_ => 1} split /\s+/, $lsview{'Properties'};
	 for (keys %properties) { splice(@ARGV, 1, 0, "-$_") if /shareable_do/ }
	 my($cachebytes) = map {(split /\s+/)[0]} map {(split /:\s*/)[1]}
			      reverse qx($CT getcache -s -view $opt{clone});
	 splice(@ARGV, 1, 0, '-cachesize', $cachebytes);
	 System($CT, @ARGV) && exit $?>>8;
	 my $cstmp = "$TmpDir/mkview.$$.cs.$opt{tag}";
	 System("$CT catcs -tag $opt{clone} > $cstmp") && exit $?>>8;
	 System("$CT setcs -tag $opt{tag} $cstmp") && exit $?>>8;
	 unlink($cstmp);
	 exit 0;
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
      StripOptions(\@ARGV, qw(cqe|nc c|cfile=s));

      # Change default: always use -rm to 'unco'.
      splice(@ARGV, 1, 0, '-rm') unless grep /^-rm$|^-kee/, @ARGV;

      # Extension: handle AutoOpt flags (parsed above).
      # Must unco in depth-first order!
      push(@ARGV, sort {$b cmp $a} CheckedOutList(\@ARGV, "keep|rm|cwork"))
	 if (keys %AutoOpt);

      # Similar to checkin/checkout hack.
      for (@ARGV[1..$#ARGV]) { $_ = readlink if -l && defined readlink }

      # Allow -user to lsco, then take it away for unco itself.
      StripOptions(\@ARGV, qw(user=s));

      last COMMAND;
   }

=item * SETVIEW/STARTVIEW/ENDVIEW

Extended to support the B<-me> flag (prepends E<lt>B<username>E<gt>_* to tag).

Also completely implements the setview command on Windows where it's
not native.  This is done by mapping a drive letter, cd-ing to that
drive, and starting a subshell. A C<-persistent> flag is supported
which causes the drive to stay mapped when done as well as C<-drive>
allowing you to specify a drive letter.

=cut

   if (/^setview$|^startview$|^endview$/) {
      delete $ENV{CLEARCASE_SHPID}; # hack - see cleartool.plx
      my %opt;
      GetOptions(\%opt, 'me');
      $ENV{LOGNAME} ||= $ENV{USERNAME};
      $ARGV[-1] = join('_', $ENV{LOGNAME}, $ARGV[-1])
		     if ($opt{me} && ($ARGV[-1] !~ /^$ENV{LOGNAME}/));
      if (/^setview$/ && $Win32) {
	 GetOptions(\%opt, qw(exec=s drive=s login ndrive persistent));
	 $opt{exec} ||= $ENV{SHELL} || $ENV{COMSPEC} || 'cmd.exe';
	 my $vtag = $ARGV[-1];
	 my @used = grep /\w:\s+\\\\/, qx(net use);
	 my @views = grep /\s+\\\\view\\$vtag\b/, grep !/unavailable/i, @used;
	 my @drives = map {/(\w:)/ && uc($1)} @views;
	 my $drive = $opt{drive} ? uc($opt{drive}) : $drives[0];
	 my $mounted = 0;
	 my $pers = $opt{persistent} ? '/persistent:yes' : '/persistent:no';
	 my %taken = map {/(\w:)\s+\\\\view(\S+)/ && uc($1) => $2} @used;
	 if (!$drive) {
	     System($CT, 'startview', $vtag) if ! -d "//view/$vtag";
	     $mounted = 1;
	     for (reverse 'A'..'Z') {
		 $drive = $_ . ':';
		 last if !$taken{$drive} &&
			 !System(qw(net use), $drive, "\\\\view\\$vtag", $pers);
	     }
	 } elsif ($opt{drive}) {
	    $drive .= ':' if $drive !~ /:$/;
	    die "cleartool: Error: $drive is in use by another view\n"
				if $taken{$drive} && $taken{$drive} ne $vtag;
	    if (! -d $drive) {
	       $mounted = 1;
	       System(qw(net use), $drive, "\\\\view\\$vtag", $pers) && exit 2;
	    }
	 }
	 chdir $drive || die "$drive $!";
	 $ENV{CLEARCASE_ROOT} = "\\\\view\\$vtag";
	 $ENV{CLEARCASE_VIEWDRIVE} = $ENV{VD} = $drive;
	 if ($mounted && !$opt{persistent}) {
	    my $rc = System $opt{exec};
	    System(qw(net use), $drive, '/delete');
	    exit $rc;
	 } else {
	    Exec($opt{exec});
	 }
      }
      last COMMAND;
   }

=item * WORKON

New command - similar to setview but sets up any required environment
variables as well. Also cd's to the I<initial working directory> within
the view. This directory is defined as the output of B<ct catcs
-start> (see).

=cut

    if (/^(rdl|workon)$/) {
	# First arg (after -me is parsed) is considered the view name
	# to make it easy to append foo=bar args.
	my %opt;
	GetOptions(\%opt, 'me');
	shift @ARGV;	# get rid of pseudo-cmd
	my $tag = shift @ARGV;
	$tag = join('_', $ENV{LOGNAME}, $tag) if $opt{me};
	for (@ARGV) {
	    if (/\s/ && !/^(["']).*\1$/) {
		$_ = qq('$_');
	    }
	}
	my $setview_cmd = "$0 _setview_exec --reread @ARGV";
	delete $ENV{CLEARCASE_SHPID}; # hack - see 'clt' script
	Exec($0, qw(setview -exec), $setview_cmd, $tag);
    }

## undocumented - helper function for B<workon>

    if (/^_setview_exec$/) {
	my $tag = (split(m%[/\\]%, $ENV{CLEARCASE_ROOT}))[-1];
	chomp(my($iwd) = Qx(qw(ct catcs --iwd --reread -tag), $tag));
	chomp(my($rdlstr) = Qx(qw(ct catcs --rdl --reread -tag), $tag));

	delete $ENV{_CT_RECURSION};

	$ENV{CLEARCASE_MAKE_COMPAT} = 'gnu';

	# Exec the user's shell
	if ($rdlstr) {
	    my @rdl = split(/\s+/, $rdlstr);
	    shift @ARGV;	# get rid of pseudo-cmd
	    push(@rdl, @ARGV);
	    my($i, $j) = (0, 0);
	    QUOTE: for (; $i <= $#rdl; $i++) {
		if (my($quote) = ($rdl[$i] =~ /(["'])/)) {
		    for ($j=$i+1; $j <= $#rdl; $j++) {
			if ($rdl[$j] =~ /$quote/) {
			    splice(@rdl, $i, 1+$j-$i, "@rdl[$i..$j]");
			    next QUOTE;
			}
		    }
		}
	    }

	    if ($iwd) {
		print "+ cd $iwd\n";
		chdir($iwd) || warn "$iwd: $!\n";
	    }
	    unshift(@rdl, 'rdl');
	    print "+ @rdl\n";
	    Exec(@rdl);
	} else {
	    if ($iwd) {
		print "+ cd $iwd\n";
		chdir($iwd) || warn "$iwd: $!\n";
	    }
	    my $sh = (-x '/bin/sh') ? '/bin/sh' : 'sh';
	    Exec($ENV{SHELL} || $sh);
	}
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
B<$CT> is the path to the real I<cleartool> program.  Also, the
hash B<%Vgra> is a reverse lookup such that C<I<$ARGV[$Vgra{xyz}] eq "xyz">>.

With most perl modules, the C<.pm> code itself (the part that gets
found via C<@INC>) is static - it's not generally modified except via
updates of the module. Meanwhile, users write code to use the module
and that code is fluid; they change it as they please.  This module is
backwards from that since the I<ct> program is policy-free and thus
shouldn't need to be changed significantly.  Meanwhile, the
B<Profile.pm> is intended to be a reflection of the local policies and
preferences; the provided B<Profile.pm> is simply a sample of what
can be done.

The B<Profile.pm> does B<not> establish a separate namespace; it operates
within C<main::>. There did not seem to be any good reason to do so,
since the whole point is to operate directly on the namespace provided
by the client program I<ct>.

The I<ct> program is normally expected to be used under that name,
which means that users running B<cleartool lsco>, for instance, will go
around the wrapper.  However, it's also designed to allow for complete
wrapping if desired. To do so, move C<$ATRIAHOME/bin/cleartool> to
C<$ATRIAHOME/bin/wrapped/cleartool> and install I<ct> as
C<$ATRIAHOME/bin/cleartool>. You can continue to install/link the wrapper
as I<ct> as well - it won't invoke the wrapper twice because it
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
