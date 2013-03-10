require 'bunny'

class StartController < ApplicationController
  unloadable

  layout 'base'
  before_filter :require_login, :except => [:index, :about, :auto_complete_for_project_name ]
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
      svn_base_path = ''

      package_key = params[:package_key]

      if params[:project_type] == 'v4_extension'
        parent_id = Project.find(Setting.plugin_flow_start['own_projects_version4_parent_identifier']).id
        base_identifier_name = Setting.plugin_flow_start['own_projects_version4_identifier_prefix']
        svn_base_path = Setting.plugin_flow_start['own_projects_version4_svn_base_path']

        svn_base_directory = Setting.plugin_flow_start['own_projects_version4_base_directory']

        if (!package_key.match(/^[a-z][a-z0-9_]*$/)) then
          flash.now[:error] = 'Your extension key has an invalid format. It should only consist of lowercase letters, numbers and underscores (_), and it must start with lowercase letters.'
          render
          return
        end

      elsif params[:project_type] == 'v5_package'
        parent_id = Project.find(Setting.plugin_flow_start['own_projects_version5_parent_identifier']).id
        base_identifier_name = Setting.plugin_flow_start['own_projects_version5_identifier_prefix']
        svn_base_path = Setting.plugin_flow_start['own_projects_version5_svn_base_path']

        svn_base_directory = Setting.plugin_flow_start['own_projects_version5_base_directory']

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

        # Add Repository to project
        @repository = Repository.factory(:Subversion)
        @repository.project = @project

        @repository.url = Setting.plugin_flow_start['own_projects_svn_base_url'] + svn_base_path + package_key
        @repository.save

        # add User to Project
        @project.members << Member.new(:user_id => User.current.id, :role_ids => [Setting.plugin_flow_start['own_projects_first_user_role_id']])

        # Write into MQ
        amqp_config = YAML.load_file("amqp.yaml")["amqp"]

        bunny = Bunny.new(host:     amqp_config["host"],
                          port:     amqp_config["port"],
                          username: amqp_config["username"],
                          password: amqp_config["password"],
                          vhost:    amqp_config["vhost"])
        bunny.start
        channel_name = "org.typo3.forge.dev.repo.svn.create"
        exchange = bunny.exchange(channel_name)
        exchange.publish("Creating new project",
                         key: channel_name,
                         headers: {
                             event:   "project_created",
                             project: package_key
                         })
        bunny.stop

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

  def about
  end
end
