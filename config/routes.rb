ActionController::Routing::Routes.draw do |map|
  map.auto_complete_projects '/projects/auto_complete',
        :controller => 'start',
        :action => 'auto_complete_for_project_name',
        :conditions => { :method => :post }

  map.create_project '/start/create_project',
        :controller => 'start',
        :action => 'createProject'

  map.create_project '/start/about',
        :controller => 'start',
        :action => 'about'
end
