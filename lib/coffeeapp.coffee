#!/usr/bin/env coffee
#
# CoffeeApp - coffee-script wrapper for CouchApp
# Copyright 2010 Andrzej Sliwa (andrzej.sliwa@i-tool.eu)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#


# fast way to imports using pattern matching
{existsSync, join, extname} = require 'path'
{mkdirSync, rmdirSync, readdirSync, writeFileSync, readFileSync, statSync, symlinkSync, unlinkSync} = require 'fs'
{compile} = require 'coffee-script'
{exec, spawn}  = require 'child_process'
{print, gets} = require 'util'
{_} = require 'underscore'
{log} = console
request = require 'request'

headers =
  accept: 'application/json',
  'content-type': 'application/json'

dumps_folder_name = '.dumps'
releases_folder_name = '.releases'

#### Command wrapping configuration.
commandWraps = [
  {
    name: 'push',
    type: 'before',
    callback: -> grindCoffee()
  },
  {
    name: 'help',
    type: 'after',
    desc: 'show this message',
    callback: -> help()
  },
  {
    name: 'cgenerate',
    type: 'before',
    desc: '[ view | list | show | filter ] generate .coffee versions',
    callback: -> generate()
  },
  {
    name: 'destroy',
    type: 'before',
    desc: '[ view | list | show | filter ] destroy (remove directory/files also .js files).',
    callback: -> destroy()
  },
  {
    name: 'prepare',
    type: 'before',
    desc: 'prepare (.gitignore...)',
    callback: -> prepare()
  },
  {
    name: 'clean',
    type: 'before',
    desc: "remove #{releases_folder_name} & #{dumps_folder_name} directories"
    callback: -> clean()
  },
  {
    name: 'restore',
    type: 'before',
    desc: "restore database from #{dumps_folder_name}/last"
    callback: -> restore()
  }
]

#### File templates

# .gitignore
gitIgnore = """
.DS_Store
.couchapprc
#{dumps_folder_name}/*
#{dumps_folder_name}/**/*
#{releases_folder_name}/*
#{releases_folder_name}/**/*
"""

# .couchappignore
couchAppIgnore = '''
[
  "spec",
  "features"
]
'''

# map function
mapCoffee = '''
(doc) ->
  ...
'''

# reduce function
reduceCoffee = '''
(keys, values, rereduce) ->
  ...
'''

# list function
listCoffee = '''
(head, req) ->
  ...
'''

# show function
showCoffee = '''
(doc, req) ->
  ...
'''

# filter function
filterCoffee = '''
(doc, req) ->
  ...
'''

#### Helper Methods

getVersion = ->
  readFileSync(join(__dirname, '..', 'package.json')).toString().match(/"version"\s*:\s*"([\d.]+)"/)[1]

showGreatings = ->
# Shows greatings ...
  log "CoffeeApp (#{getVersion()}) - simple coffee-script wrapper for CouchApp (http://couchapp.org)"
  log 'http://github.com/andrzejsliwa/coffeeapp\n'

spaces = (string, max) ->
  count = max - string.length
  result = ""
  while count > 0
    result += " "
    count--
  result

# Zero padding for format '0x'
padTwo = (number) ->
  result = if number < 10 then '0' else ''
  "#{result}#{number}"

# Timestamp string based on current date
getTimestamp = ->
  date = new Date
  date.getFullYear() + padTwo(date.getMonth() + 1) +
  padTwo(date.getDate()) + padTwo(date.getHours() + 1) +
  padTwo(date.getMinutes() + 1) + padTwo(date.getSeconds() + 1)

# Display outputs if presents
handleOutput = (callbackOk, callbackError) ->
  (error, stdout, stderr) ->
    log(stdout) if stdout.length > 0
    log(stderr) if stderr.length > 0
    if error != null
      callbackError() if callbackError != undefined
    else
      callbackOk() if callbackOk != undefined

getConfig = ->
  JSON.parse readFileSync '.couchapprc', 'utf8'

getDirectories = (currentDir, ignores) ->
  callback = (name) ->
    statSync(join currentDir, name).isDirectory()
  filterDirectory currentDir, callback, ignores

getFiles = (currentDir, ignores) ->
  callback = (name) ->
    !statSync(join currentDir, name).isDirectory()
  filterDirectory currentDir, callback, ignores

filterDirectory = (currentDir, callback, ignores) ->
  list = readdirSync currentDir
  if ignores
    list = _.without(list, ignores...)
  results = _.filter list, callback

#### Main Methods

# Process directory "recursivly", normal files
# are copied, directories are recreated and .coffee
# files are "compiled" to javascript
processDirectory = (baseDir, destination) ->
  dirs = [baseDir]
  isError = false
  while (dirs.length > 0)
    currentDir = dirs.pop()
    subDirs = getDirectories currentDir, ['.git', releases_folder_name, dumps_folder_name]
    _.each subDirs, (dirName) ->
      dirPath = join currentDir, dirName
      dirs.push dirPath
      destDirPath = join destination, join dirPath
      mkdirSync destDirPath, 0700


    files = getFiles currentDir
    _.each files, (fileName) ->
      filePath = join currentDir, fileName
      destFilePath = join destination, filePath
      if extname(filePath) == ".coffee"
        log " * processing #{filePath}..."
        try
          writeFileSync destFilePath.replace(/\.coffee$/, '.js'),
            compile(readFileSync(filePath, 'utf8'), bare: yes), 'utf8'
        catch error
          log "Compilation Error: #{error.message}\n"
          isError = true
      else
        writeFileSync destFilePath, readFileSync(filePath, 'binary'), 'binary'
  !isError

#### Grinding of coffee

# Starts wrapping push command of couchapps
#
# each deploy is moved to .releases/[timestamp] directory
# with processing coffee-script files and then pushed from
# deploy directory.
grindCoffee = ->
  log "Wrapping 'push' of couchapp"
  config = getConfig()
  timestamp = getTimestamp()
  makeReleaseVersions = config['makeReleaseVersions'] isnt false
  designdocName = config['designdocName'] or "app"
  releasesDir = releases_folder_name
  unless existsSync releasesDir
    log "initialize #{releasesDir} directory"
    mkdirSync releasesDir, 0700
  if makeReleaseVersions
    releasePath = join releasesDir, timestamp
  else
    releasePath = join releasesDir, designdocName
    log "Removing #{releasePath}"
    rmTreeSync releasePath

  [options, database] = processOptions()

  log "database : '#{database}'"
  processCallback = ->
    log "preparing release: #{releasePath}"
    mkdirSync releasePath, 0700
    if processDirectory '.', releasePath
      process.chdir releasePath
      exec "couchapp #{options} #{database}", handleOutput()
      process.cwd

  if config['env'][database]['make_dumps']
    dumpsDir = join dumps_folder_name, database
    unless existsSync dumps_folder_name
      log "initialize #{dumps_folder_name} directory"
      mkdirSync dumps_folder_name, 0700
    unless existsSync dumpsDir
      log "initialize #{dumpsDir} directory"
      mkdirSync dumpsDir, 0700
    dumpsPath = join dumpsDir, timestamp

    log "making dump: #{dumpsPath}"
    url = config['env'][database]['db']
    exec "couchdb-dump #{url} > #{dumpsPath}", handleOutput ->
      lastPath = join dumpsDir, 'last'
      unlinkSync lastPath if existsSync lastPath
      log " * linking dump: #{dumpsPath} -> #{lastPath}"
      symlinkSync timestamp, "#{lastPath}"
      processCallback()
  else
    processCallback()

processOptions = ->
  [options..., database] = process.argv[2..]
  options = (options || []).join ' '
  database = "default" if database == undefined
  if process.argv[2..].length == 1
    options = database
    database = "default"
  return [options, database]

# Shows available options.
help = ->
  log "Wrapping 'help' of couchapp\n"
  showGreatings()

  usage = '''
Usage: coffeeapp [OPTIONS] [CMD] [CMDOPTIONS] [ARGS,...]

Commands:
'''
  log usage
  _.each commandWraps, (command) ->
    if command.desc
      log "        #{command.name}#{spaces(command.name, 9)} [OPTIONS]..."
      log "                  #{command.desc}\n"

# generate file from template verbosly
generateFile = (path, template) ->
  log " * creating #{path}..."
  if existsSync path
    log "File #{path} already exist!"
  else
    writeFileSync path, template, 'utf8'


# cgenerate and destory handling
generate = -> operateOn('generate')
destroy = -> operateOn('destroy')

# common handling for cgenerate/destroy
operateOn = (command) ->
  generator = process.argv[2..][1]
  unless generator
    log "missing name of #{command} - [ view | list | show | filter ]"
    return
  name = process.argv[2..][2]
  unless name
    log 'missing name of element'
    return
  print "Running #{generator} #{command}:\n"
  fun = switch generator
    when 'view'
      handleView
    when 'show'
      handleShow
    when 'list'
      handleList
    when 'filter'
      handleFilter
    else
      (method, name) -> log "unknown #{command}"
  log 'done.' if fun(command, name)

# handling view generate/destroy
handleView = (method, name) ->
  unless existsSync 'views'
    mkdirSync 'views', 0700

  viewDirPath = "views/#{name}"
  [mapFilePath, reduceFilePath] = [join(viewDirPath, "map.coffee"), join(viewDirPath, "reduce.coffee")]
  switch method
    when 'generate'
      if existsSync viewDirPath
        log "directory '#{viewDirPath}' already exist!"
        false
      else
        mkdirSync viewDirPath, 0700
        generateFile mapFilePath, mapCoffee
        generateFile reduceFilePath, reduceCoffee
        true
    when 'destroy'
      if existsSync viewDirPath
        log "'#{viewDirPath}'."
        exec "rm -r #{viewDirPath}", handleOutput()
        true
      else
        log "there is no view '#{name}' ('#{viewDirPath}') !!!"
        false
    else
      throw 'unknown method'

# handling generic generate/destroy of file
handleFile = (method, folder, template, name) ->
  filePathCoffee = join folder, "#{name}.coffee"
  filePathJS = join folder, "#{name}.js"
  switch method
    when 'generate'
      unless existsSync folder
        mkdirSync folder, 0700
      generateFile filePathCoffee, template
      true
    when 'destroy'
      if existsSync filePathCoffee
        log "'#{filePathCoffee}'."
        exec "rm #{filePathCoffee}", handleOutput()
        true
      else if existsSync filePathJS
        log "'#{filePathJS}'."
        exec "rm #{filePathJS}", handleOutput()
        true
      else
        log "there is no '#{name}' ('#{filePathJS}' or '#{filePathCoffee}') !!!"
        false
    else
      throw 'unknown method'

# shortcuts of handling generate/destroy
handleShow = (method, name) -> handleFile(method, 'shows', showCoffee, name)
handleList = (method, name) -> handleFile(method, 'lists', listCoffee, name)
handleFilter = (method, name) -> handleFile(method, 'filters', filterCoffee, name)

# make clean up
clean = ->
  log "cleaning up:"
  log " * remove '#{releases_folder_name}' ..."
  exec "rm -r #{releases_folder_name}", handleOutput ->
    log " * remove '#{dumps_folder_name}' ..."
    exec "rm -r #{dumps_folder_name}", handleOutput ->
      log "done."
    , ->
      log "there is no '#{dumps_folder_name}' directory!"
  , ->
    log "there is no '#{releases_folder_name}' directory!"

# prepare project
prepare = ->
  log "preparing project:"
  generateFile '.gitignore', gitIgnore
  generateFile '.couchappignore', couchAppIgnore
  log "done."


restore = ->
  [options, database] = processOptions()
  config = getConfig()
  lastPath = join dumps_folder_name, database, 'last'
  unless existsSync lastPath
    log "There is no dump!"
    return
  if config['env'][database]['make_dumps']
    log "restoring dump from #{lastPath} to database: #{}"
    url = config['env'][database]['db']
    request {uri: url, method: 'DELETE', headers: headers}, (error, response, body) ->
      if response.statusCode == 200
        request {uri: url, method: 'PUT', headers: headers}, (error, response, body) ->
          unless response.statusCode == 200
            message = JSON.parse(body)
            if message.error
              log "Error: #{message.error} - #{message.reason}"
      else
        message = JSON.parse(body)
        if message.error
          log "Error: #{message.error} - #{message.reason}"
    exec "couchdb-load #{url} --input #{lastPath}", handleOutput ->
      log "done."
  else
    log "you don't using dumps for this database... look in couchapprc for make_dumps."

rmTreeSync = (path) ->
  return  unless existsSync(path)
  files = readdirSync(path)
  unless files.length
    rmdirSync path
    return
  else
    files.forEach (file) ->
      fullName = join(path, file)
      if statSync(fullName).isDirectory()
        rmTreeSync fullName
      else
        unlinkSync fullName
  rmdirSync path

# Handle wrapping
handleCommand = (type) ->
  handled = false
  name = process.argv[2..][0]
  name = "help" if name == undefined
  _.each commandWraps, (cmd) ->
    if cmd.type == type && cmd.name == name
      handled = true
      cmd.callback()
  handled

missingPythonDeps = (commandName, packageName) ->
  log " * missing #{commandName} !"
  log "   try... pip install #{packageName}"
  log "   or...  easy_install #{packageName}"
  process.exit -1

#### Well, let's dance baby
exports.run = ->
  showGreatings()

  ok_callback = ->
    unless handleCommand 'before'
      # convert options back to string
      options = process.argv[2..].join ' '
      # execute couchapp command
      exec "couchapp #{options}", handleOutput ->
        handleCommand 'after'

  exec 'couchapp --version > /dev/null', handleOutput ->
    config = getConfig()
    [options, database] = processOptions()
    if config['env'][database]['make_dumps']
      exec 'couchdb-dump --version > /dev/null', handleOutput ok_callback, ->
        missingPythonDeps("couch-dump", "couchdb")
    else
      ok_callback()
  , ->
    missingPythonDeps "couchdb-dump", "couchdb"







