use ExtUtils::MakeMaker;
use File::Copy;
my $Name;

# Generate an HTML file from the Profile.pm POD.
system qw(pod2html lib/ClearCase/Ct/Profile.pm --outfile=Readme.html);


# Hack to allow installer to choose name of front-end cmd.
if (! -f Makefile) {
   print qq(
      This module installs a front end to cleartool.  By default
      it's called 'ct', because that appears to be the most common
      alias for cleartool, but it can be called whatever you like
      (some would argue that ct is inappropriate because there's a
      Unix utility of the same name - common alternatives might
      include 'cl' and 'clt', or even just 'c').);

   print "\n\nWhat do you want to call the front-end program? [ct] ";
   $Name = <STDIN>;
   chomp $Name;
   $Name ||= 'ct';
   unlink $Name;
   copy('cleartool.plx', $Name) || die "$Name: $!";
   print "Ok, it will be installed as '$Name' ...\n\n";
   if ($^O =~ /win32/i) {
      warn "pl2bat $Name ...\n";
      system('pl2bat', $Name);
   } else {
      chmod 0555, $Name || warn "$Name: $!";
   }
}

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	=> 'ClearCase::Ct',
    'VERSION_FROM' => 'Ct.pm', # finds $VERSION
    'EXE_FILES' => [ $Name ],
    'realclean' => { FILES => $Name },
    'dist' => {
	  # This is a hack to make sure I don't distribute without removing
	  # my site-specific modifications.
	  PREOP => 'grep /usr/local/bin cleartool.plx',
	  DIST_DEFAULT => 'all tardist',
	  SUFFIX => '.gz',
	  COMPRESS => 'gzip -f',
	  POSTOP => q(rm -f cleartool.plx.orig && ct unco -rm cleartool.plx ||:),
    },
);
