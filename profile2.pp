# /etc/puppetlabs/code/environments/production/site/profile/manifests/jenkins/master.pp
class profile::jenkins::master (
  String  $jenkins_port = '9091',
  Boolean $install_jenkins_java = true,
) {

  class { 'jenkins':
    configure_firewall => true,
    install_java       => $install_jenkins_java,
    port               => $jenkins_port,
    config_hash        => {
      'HTTP_PORT'    => { 'value' => $jenkins_port },
      'JENKINS_PORT' => { 'value' => $jenkins_port },
    },
  }

  # When not using the jenkins module's java version, install java8.
  unless $install_jenkins_java  { include profile::jenkins::usage::java8 }

  # Manage the heap size on the master, in MB.
  if($::memorysize_mb =~ Number and $::memorysize_mb > 8192)
  {
    # anything over 8GB we should keep max 4GB for OS and others
    $heap = sprintf('%.0f', $::memorysize_mb - 4096)
  } else {
    # This is calculated as 50% of the total memory.
    $heap = sprintf('%.0f', $::memorysize_mb * 0.5)
  }
  # Set java params, like heap min and max sizes. See
  # https://wiki.jenkins-ci.org/display/JENKINS/Features+controlled+by+system+properties
  jenkins::sysconfig { 'JAVA_ARGS':
    value => "-Xms${heap}m -Xmx${heap}m -Djava.awt.headless=true -XX:+UseConcMarkSweepGC -XX:+CMSClassUnloadingEnabled -Dhudson.model.DirectoryBrowserSupport.CSP=\\\"default-src 'self'; img-src 'self'; style-src 'self';\\\"",
  }

}
