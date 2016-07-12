---
title: "Roles and profiles: A complete example"
---

[jenkins_module]: https://forge.puppet.com/rtyler/jenkins
[jenkins]: TODO
[java_module]: TODO
[auto_params]: TODO
[puppet strings]: TODO
[modules]: TODO
[hiera]: TODO
[puppet lookup]: TODO
[include]: TODO
[resource-like]: TODO
[pe console]: TODO
[main manifest]: TODO
[node statements]: TODO

This simple, but not oversimplified example demonstrates a complete roles and profiles workflow.

Use it to understand the roles and profiles method as a whole. Subsequent examples show how to design advanced configurations by refactoring this example code to a higher level of complexity.

## Our example: Jenkins masters

[Jenkins][] is a continuous integration (CI) application that runs on a JVM. The Jenkins master server provides a web front-end, and also runs CI tasks at scheduled times or in reaction to events.

For our main example, we'll manage the configuration of our Jenkins master servers.

## Step 0: Set up your prerequisites

If you're new to using roles and profiles, do some additional setup before writing any new code.

1. Create two [modules][]: one named `role`, and one named `profile`.
    If you deploy your code with Puppet Enterprise's code manager or r10k, put these two modules in your control repository instead of declaring them in your Puppetfile. (You can do it either way, but this way gives better results for most people.) Make a directory named `site` in the repo, and edit the `environment.conf` file to add that directory to the `modulepath`.
2. Make sure [Hiera][] or [Puppet lookup][] is set up and working, with a hierarchy that works well for you.

## Step 1: Choose component modules

1. For our example, we want to manage Jenkins itself. The standard module for that is [`rtyler/jenkins`][jenkins_module].
2. Jenkins requires Java, and the `rtyler` module can manage it automatically. But we want finer control over Java, so we're going to disable that. So, we need a Java module, and [`puppetlabs/java`][java_module] is a good choice.

That's enough to start with; we can refactor and expand once we have those working.

## Step 2: Write a profile

From Puppet's perspective, a profile is just a normal class stored in the `profile` module. So we'll make a new class called `profile::jenkins::master`, located at `.../profile/manifests/jenkins/master.pp`, and fill it with Puppet code.

### The rules for profiles classes

* Make profiles work safely with [the `include` function][include] --- don't use [resource-like declarations][resource-like] on them.
* Profiles can `include` other profiles.
* Profiles own _all_ the class parameters for their component classes. If the profile omits one, that means you definitely want the default value; the component class shouldn't use a value from Hiera data. If you need to set a class parameter that was omitted previously, refactor the profile.
* There are three ways a profile can get the information it needs to configure component classes:
    * If your business will always use the same value for a given parameter, **hardcode it.**
    * If you can't hardcode it, try to **compute it** based on information you already have.
    * Finally, if you can't compute it, **look it up** in your data. To reduce lookups, identify cases where multiple parameters can be derived from the answer to a single question.

    This is a game of trade-offs. Hardcoded parameters are the easiest to read, and also the least flexible. Putting values in your Hiera data is very flexible, but can impede performance and can be very difficult to read: you might have to look through a lot of files (or run a lot of lookup commands) to see what the profile is actually doing. Using conditional logic to derive a value is a middle-ground.

    Aim for the most readable option you can get away with.

### The sample profile code

``` puppet
# /etc/puppetlabs/code/environments/production/site/profile/manifests/jenkins/master.pp
class profile::jenkins::master (
  String $jenkins_port = '9091',
  String $java_dist    = 'jdk',
  String $java_version = 'latest',
) {

  class { 'jenkins':
    configure_firewall => true,
    install_java       => false,
    port               => $jenkins_port,
    config_hash        => {
      'HTTP_PORT'    => { 'value' => $jenkins_port },
      'JENKINS_PORT' => { 'value' => $jenkins_port },
    },
  }

  class { 'java':
    distribution => $java_dist,
    version      => $java_version,
    before       => Class['jenkins'],
  }
}
```

This is pretty simple, but is already benefiting us: our interface for configuring Jenkins has gone from 30 or so parameters on the Jenkins class (and many more on the Java class) down to three. Notice that we've hardcoded the `configure_firewall` and `install_java` parameters, and have reused the value of `$jenkins_port` in three places.

### About data and class parameters

Profiles usually require some amount of configuration, and they must use data lookup to get it.

In this profile, we use [automatic class parameter lookup][auto_params] to request data. But we also could have omitted the parameters and used the `lookup` function:

``` puppet
class profile::jenkins {
  $jenkins_port = lookup('profile::jenkins::jenkins_port', {value_type => String, default_value => '9091'})
  $java_dist    = lookup('profile::jenkins::java_dist',    {value_type => String, default_value => 'jdk'})
  $java_version = lookup('profile::jenkins::java_version', {value_type => String, default_value => 'latest'})
  # ...
```

In general, class parameters are better. They integrate better with tools like [Puppet Strings][], and they're a reliable and well-known place to look for configuration. But using `lookup` is a fine approach if you aren't comfortable with automatic parameter lookup. Some people prefer the full lookup key to be written in the profile, so they can globally grep for it.

## Step 3: Set Hiera data for the profile

Let's assume the following:

- We use some custom facts:
    - `group`: The group this node belongs to. (This is usually either a department of our business, or a large-scale function shared by many nodes.)
    - `stage`: The deployment stage of this node (dev, test, or prod).
- We have a four-layer hierarchy:
    - `nodes/%{trusted.certname}` for per-node overrides.
    - `groups/%{facts.group}/%{facts.stage}` for setting stage-specific data within a group.
    - `groups/%{facts.group}` for setting group-specific data.
    - `common` for global fallback data.
- We have a few one-off Jenkins masters, but most of them belong to the `ci` group.
- Our quality engineering department wants masters in the `ci` group to use the Oracle JDK, but one-off machines can just use the platform's default Java.
- QE also wants their prod masters to listen on port 80.

So, we'll set the following values in our data:

``` yaml
# /etc/puppetlabs/code/environments/production/data/nodes/ci-master01.example.com.yaml
# --Nothing. We don't need any per-node values right now.

# /etc/puppetlabs/code/environments/production/data/groups/ci/prod.yaml
profile::jenkins::master::jenkins_port: '80'

# /etc/puppetlabs/code/environments/production/data/groups/ci.yaml
profile::jenkins::master::java_dist: 'oracle-jdk8'
profile::jenkins::master::java_version: '8u92'

# /etc/puppetlabs/code/environments/production/data/common.yaml
# --Nothing. Just use the default parameter values.
```

## Step 4: Write a role

Next, we consider the machines we'll be managing and decide what else they need in addition to that Jenkins profile.

Our Jenkins masters don't serve any other purpose. But we have some profiles (code not shown) that we expect every machine in our fleet to have:

* `profile::base` must be assigned to every machine, including workstations. It manages basic policies, and uses some conditional logic to include OS-specific profiles as needed.
* `profile::server` must be assigned to every machine that provides a service over the network. It makes sure ops can log into the machine, and configures things like timekeeping, firewalls, logging, and monitoring.

So a role that configures a node to be one of our Jenkins masters looks like this:

``` puppet
class role::jenkins::master {
  include profile::base
  include profile::server
  include profile::jenkins::master
}
```

## Step 5: Assign the role to nodes

Finally, we assign `role::jenkins::master` to every node that acts as a Jenkins master.

Puppet has several ways to assign classes to nodes, so use whichever tool you feel best fits your team. Your main choices are:

* The [PE console][] node classifier, which lets you group nodes based on their facts and assign classes to those groups.
* The [main manifest][], which can use [node statements][] or conditional logic to assign classes.
* Hiera or Puppet lookup --- use the `lookup` function to do a unique array merge on a special `classes` key, and pass the resulting array to the `include` function.

