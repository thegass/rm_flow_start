require 'bunny'
require 'json'
require 'yaml'

class StartController < ApplicationController
  unloadable

  layout 'base'
  before_filter :require_login, :except => [:index, :auto_complete_for_project_name ]
  include ProjectsHelper

  def index
    @news = News.latest User.current, 2

    @random_users = User.find(:all, :limit => 10, :order => 'RAND()', :conditions => "img_hash != ''")

    #@projects = Project.list User.current
    #projects = Project.find :all,
    #            :conditions => Project.visible_by(User.current),
    #:include => :parent
    #@projects = projects
    #@project_tree = projects.group_by {|p| p.parent || p}
    #@project_tree.each_key {|p| @project_tree[p] -= [p]}
  end

  def auto_complete_for_project_name
    query = '%' + params[:projectname][:project].downcase + '%' 
    find_options = {
      :conditions => [ "( identifier LIKE ? OR LOWER(name) LIKE ? ) AND "+Project.visible_condition(User.current), query, query ],
      :order => "identifier ASC",
      :limit => 10 }
      @items = Project.find(:all, find_options)
      render :partial => 'project_autocompleter'
  end

  def createProject
    if request.get?
      # Display "create project" Form
    else

      base_identifier_name = ''
      parent_id = 0
      git_base_path = ''
      create_repo = false  # user must check the "create repo" box to override
      force_review = false # user must check the "force review" box to override

      package_key = params[:package_key]

      if params[:project_type] == 'v4_extension'
        parent_id = Project.find(Setting.plugin_flow_start['own_projects_version4_parent_identifier']).id
        base_identifier_name = Setting.plugin_flow_start['own_projects_version4_identifier_prefix']
        git_base_path = Setting.plugin_flow_start['own_projects_version4_git_base_path']

        git_base_directory = Setting.plugin_flow_start['own_projects_version4_base_directory']

        if (!package_key.match(/^[a-z][a-z0-9_]*$/)) then
          flash.now[:error] = 'Your extension key has an invalid format. It should only consist of lowercase letters, numbers and underscores (_), and it must start with lowercase letters.'
          render
          return
        end

      elsif params[:project_type] == 'v5_package'
        parent_id = Project.find(Setting.plugin_flow_start['own_projects_version5_parent_identifier']).id
        base_identifier_name = Setting.plugin_flow_start['own_projects_version5_identifier_prefix']
        git_base_path = Setting.plugin_flow_start['own_projects_version5_git_base_path']

        git_base_directory = Setting.plugin_flow_start['own_projects_version5_base_directory']

        if (!package_key.match(/^[A-Z][a-zA-Z0-9_]*$/)) then
          flash.now[:error] = 'Your extension key has an invalid format. It should be written UpperCamelCased.'
          render
          return
        end

      else
        flash.now[:error] = 'System error. Unfortunately the system was not able to complete your request. Please file a bug.'
      end

      if (params[:package_key] and params[:package_key].empty?) then
        flash.now[:error] = 'You did not specify a package key!'
        render
        return
      end

      if (params[:project_name] and params[:project_name].empty?) then
        flash.now[:error] = 'You did not specify a name!'
        render
        return
      end

      # enable creation of repo ?
      if (params[:create_repo] and params[:create_repo] == 'yes') then
        create_repo = true
      end

      # influence default permissions inside gerrit when repo is created
      # enable/force review on the git repo (commits have to go through refs/for)
      if (params[:force_review] and params[:force_review] == 'yes') then
        force_review = true
      else
        force_review = false
      end

      identifier_name = base_identifier_name + package_key.downcase

      #      logger.info "OWN ProjectName: "+params[:project_name].to_s
      #      logger.info "OWN PID: "+parent_id.to_s
      #            logger.info "OWN Desc: "+params[:description]
      #                  logger.info "OWN Identifier: "+identifier_name

      @project = Project.new(
        :name => params[:project_name],
        #        :parent_id => parent_id,
        :description => params[:description],
        :identifier => identifier_name,
        :is_public => 0
      )
      @project.enabled_module_names = Redmine::AccessControl.available_project_modules
      if @project.save
        @project.set_parent!(parent_id)

        logger.info "Creating project @project, triggered by #{User.current.login} (#{User.current.id})"

        # add User to Project
        @project.members << Member.new(:user_id => User.current.id, :role_ids => [Setting.plugin_flow_start['own_projects_first_user_role_id']])

        # only create repo in case it was requested
        # @todo refactor into service/method so it can be reused outside of the start controller
        if create_repo then
          # Add Repository to project
          @repository = Repository.factory(:Git)
          @repository.project = @project

          repo_path = Setting.plugin_flow_start['own_projects_version4_base_directory'] + package_key + ".git"
          @repository.url = 'file://' + repo_path
          @repository.save

          logger.info "Setting up Git repository in #{repo_path}"
          custom_system 'git init --bare ' + repo_path
          git_server_url = Setting.plugin_flow_start['own_projects_git_base_url'] + Setting.plugin_flow_start['own_projects_version4_git_base_path'] + package_key + '.git'

          # Write into MQ
          amqp_config = YAML.load_file("config/amqp.yml")["amqp"]

          logger.info "Read AMQP config, connecting to amqp://#{amqp_config["username"]}@#{amqp_config["host"]}:#{amqp_config["port"]}/#{amqp_config["vhost"]}"

          bunny = Bunny.new(:host  => amqp_config["host"],
                            :port  => amqp_config["port"],
                            :user  => amqp_config["username"],
                            :pass  => amqp_config["password"],
                            :vhost => amqp_config["vhost"])
          bunny.start

          logger.info "Connected to #{amqp_config["host"]}"

          channel_name = "org.typo3.forge.repo.git.create"

          logger.info "Creating channel #{channel_name}"
          channel = bunny.create_channel

          logger.info "Connecting to exchange #{channel_name}"
          exchange = channel.fanout(channel_name, :durable => true)

          message_data = {
              :event  =>  "project_created",
              :project => package_key,
              :project_path => git_base_path,
              :force_review => force_review
          }

          message_metadata = {
              :routing_key => channel_name,
              :persistent => true,
              :mandatory => true,
              :content_type => "application/json",
              :user_id => amqp_config["username"],
              :app_id => "redmine on #{request.host}"
          }

          logger.info "Trying to publish message: #{message_data.to_json} with metadata: #{message_metadata.to_json}"

          exchange.publish(message_data.to_json, message_metadata)

          logger.info "Message published"

          bunny.stop
        end #
        flash[:notice] = l(:notice_successful_create)
        render :action => :projectSuccessfullyCreated
      else # if !@project.save 
        flash.now[:error] = "Unable to create the project. Please try a shorter project name."  # @project.errors.full_messages.join(" ")
        render
      end # if @project.save
    end # if request.get
  end

  def custom_system(command)
    #    RAILS_DEFAULT_LOGGER.info("OWN SYSTEM "+command)
    system(command)
  end

  def projectSuccessfullyCreated
    @project = Project.find("packages")
  end

end
