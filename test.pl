# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

my $cchome = $ENV{ATRIAHOME} || ($^O =~ /win32/i ? 'C:/atria' : '/usr/atria');

if (! -d $cchome) {
   warn "\nNo ClearCase installed on this system, skipping test ...\n";
   exit 0
}

# Hack to propagate enhanced @INC into child processes below.
{ local $" = ':'; $ENV{PERL5LIB} .= "@INC" }

### This is a pretty trivial test, but then the only valid requirement
### you can make of this module is that it act as a wrapper to cleartool ...
### any specific functionality delivered in the profile file is provided
### as an example only and I specifically do not want to test it here.

if (system('perl', './cleartool.plx', 'pwv')) {
   print "not ok 1\n";
} else {
   print "ok 1\n";
}
