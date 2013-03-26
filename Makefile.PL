use 5.014002;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'MR::AsyncHTTP',
    VERSION_FROM      => 'lib/MR/AsyncHTTP.pm', # finds $VERSION
    PREREQ_PM         => {
		'Carp' => 0,
		'Socket' => 0,
		'Fcntl' => 0,
		'Time::HiRes' => 0,
	},
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/MR/AsyncHTTP.pm', # retrieve abstract from module
       AUTHOR         => 'Alt <alt@cpan.org>') : ()),
);
