# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

my $cchome = $ENV{ATRIAHOME} || ($^O =~ /win32/i ? 'C:/atria' : '/usr/atria');

if (! -d $cchome) {
   warn "\nNo ClearCase installed on this system, skipping test ...\n";
   exit 0
}

# Hack to propagate enhanced @INC into child processes below.
{ local $" = ($^O =~ /win32/i) ? ';' : ':'; $ENV{PERL5LIB} .= "@INC" }

### This is a pretty trivial test, but then the only valid requirement
### you can make of this module is that it act as a wrapper to cleartool ...
### any specific functionality delivered in the profile file is provided
### as an example only and I specifically do not want to test it here.

## Note: on NT4.0, with perl 5.005_02 as built by ActiveState, the
## test seems to fail with a complaint about the fastcwd() function. Not
## sure why but it works fine once installed. Apparently the blib setup
## isn't quite right?? Anyway, this is a workaround.
$ENV{PWD} ||= '.' if $^O =~ /win32/i;

if (system('perl', './cleartool.plx', 'pwv')) {
   print "not ok 1\n";
} else {
   print "ok 1\n";
}
