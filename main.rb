require 'find'
require 'json'
require 'xcodeproj'
require 'open3'

def env_has_key(key)
	return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end


#Check if root path exist
temporary_path = env_has_key("AC_TEMP_DIR")
repository_path = env_has_key("AC_REPOSITORY_DIR")
xcode_list_path = env_has_key("AC_XCODE_LIST_DIR")

#Find targets
def get_launchable_targets(project)
    launchable_targets = []
    project.native_targets.each do |target|
        if target.launchable_target_type?
            launchable_targets.push(target)
        end
    end
    return launchable_targets
end

def get_bundle_identifiers(target)
    bundle_identifiers = []

    target.build_configurations.each { |configuration|

        b_id = configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"]
        unless b_id.nil?
            unless bundle_identifiers.include? b_id
                bundle_identifiers.push(b_id)
            end
        end
        

    }

    return bundle_identifiers
end

def get_embedded_and_watch_targets(project, launchable_target)
    targets = []
    embedded_targets = project.embedded_targets_in_native_target(launchable_target)
    embedded_targets.each do |embedded|
        if embedded.extension_target_type?
            targets.push({"name" => embedded.to_s,"bundleIdentifiers" => get_bundle_identifiers(embedded)})
            #Watch App
        elsif embedded.product_type.match(/com.apple.product-type.application.watchapp/)
            targets.push({"name" => embedded,"bundleIdentifiers" => get_bundle_identifiers(embedded)})
            embedded_watch_targets = project.embedded_targets_in_native_target(embedded)
            embedded_watch_targets.each do |embedded_watch|
                if embedded_watch.extension_target_type?
                    targets.push({"name" => embedded_watch.to_s,"bundleIdentifiers" => get_bundle_identifiers(embedded_watch)})
                end
            end
        end
    end
    
    return targets
end

#Find projects & schemes
project_paths_schemes = []
none_exist_launchable_projects = []
Find.find("#{repository_path}") do |p|
    if File.extname(p) == ".xcodeproj"
        begin

            project = Xcodeproj::Project.open(p)
            # project.recreate_user_schemes
            paths_schemes = {}
            paths_schemes["path"] = ".#{p.split(repository_path)[1]}"
            paths_schemes["type"] = "project"
            launchable_targets = get_launchable_targets(project)

            if launchable_targets.empty?
                none_exist_launchable_projects.push(paths_schemes["path"]) 
                Find.prune 
            end

            paths_schemes["schemes"] = []
            launchable_targets.each do |target|
                schemes = Dir[File.join(p, 'xcshareddata', 'xcschemes', '*.xcscheme')]
                if schemes.empty?
                    bundle_identifiers = get_bundle_identifiers(target)
                    scheme = File.basename(p, '.xcodeproj')
                    extensions = get_embedded_and_watch_targets(project,target)
                    paths_schemes["schemes"].push({
                        "name" => scheme,
                        "bundleIdentifiers" => bundle_identifiers,
                        "extensions" => extensions
                    })
                else
                    schemes.each do |arr_scheme|
                        entries = Xcodeproj::XCScheme.new(arr_scheme).build_action.entries
                        #Schemes multi launch target does not support
                        unless entries.nil?
                            entries.each do |arr_entries|
                                if arr_entries.buildable_references[0]
                                    if target.uuid == arr_entries.buildable_references[0].target_uuid
                                        bundle_identifiers = get_bundle_identifiers(target)
                                        scheme = File.basename(arr_scheme, '.xcscheme')
                                        extensions = get_embedded_and_watch_targets(project,target)
                                        paths_schemes["schemes"].push({
                                            "name" => scheme,
                                            "bundleIdentifiers" => bundle_identifiers,
                                            "extensions" => extensions
                                        })
                                    end
                                end
                            end
                        end
                    end
                end
            end

            puts "\nProject:"
            puts "#{paths_schemes}\n"
            project_paths_schemes << paths_schemes
        rescue Exception => e  
            puts e.message
            puts e.backtrace
        end

        Find.prune
    end
end

#Find workspaces & schemes
workspace_paths_schemes = []
Find.find("#{repository_path}") do |p|
    if File.extname(p) == ".xcworkspace"
        begin
            paths_schemes = {}
            paths_schemes["path"] = ".#{p.split(repository_path)[1]}"
            paths_schemes["type"] = "workspace"
            workspace = Xcodeproj::Workspace.new_from_xcworkspace(p)
            # workspace.load_schemes(p)
            projects = []
            workspace.file_references.each do |file|
                if !(none_exist_launchable_projects.include? "#{File.join(File.dirname(paths_schemes["path"]),file.path)}") && File.exist?(File.join(File.dirname(p),file.path))
                    projects.push(".#{File.expand_path((File.join(File.dirname(p),file.path)).split(repository_path)[1])}")
                end
            end

            unless projects.count === 0 
                paths_schemes["projects"] = projects

                puts "\nWorkspace:"
                puts "#{paths_schemes}\n"
                workspace_paths_schemes << paths_schemes
            end
            
        rescue
        end

        Find.prune
    elsif File.extname(p) == ".xcodeproj"
        Find.prune
    end
end

#Combine
project_workspace_paths = {};
project_workspace_paths['projects'] = []
# project_workspace_paths['workspaces'] = workspace_paths_schemes
workspace_paths_schemes.each do |workspace|
    path = workspace["path"]
    type = workspace["type"]
    schemes = []
    workspace["projects"].each do |project|
        project_paths_schemes.each do |inner_project|
            if inner_project["path"] == project
                schemes.concat(inner_project["schemes"])
                break
            end
        end
    end
    project_workspace_paths['projects'].push({
        "path" => path,
        "type" => type,
        "schemes" => schemes
    })
end

project_workspace_paths['projects'].concat(project_paths_schemes)

xcode_versions = []
if File.directory? xcode_list_path
    Dir.chdir(xcode_list_path) do
        Dir.glob('*').select { |f| 
            File.directory? f 
            xcode_versions << "#{f}"
        }
    end
end

sort_list = xcode_versions.sort do |a, b|
  case
  when a.to_f < b.to_f
    1
  when a.to_f > b.to_f
    -1
  else
    a <=> b
  end
end 

project_workspace_paths['xcodeVersions'] = sort_list

output_path = "#{temporary_path}/metadata.json"
File.open("#{output_path}", "w") { |file| file.write(project_workspace_paths.to_json) }

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "AC_METADATA_OUTPUT_PATH=#{output_path}"
}

exit 0