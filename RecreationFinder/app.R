# Recreation Finder
# R Shiny Web App
# Build Date: 7/8/25
# Author: Mike Keating

library(shiny)
library(DT)
library(bslib)
library(leaflet) # For mapping

# Import our custom functions
source("ridb_api_functions.R")
source("ridb_plot_functions.R")

# Set one of the bslib themes
theme <- bs_theme(bootswatch = "flatly")

ui <- page_fluid(
  theme = theme,
  navset_tab(
    nav_panel("About",
              fluidPage(
                h2("About This App"),
                HTML("
      <p><strong>Recreation Finder</strong> is a Shiny app built to explore recreational facilities across the United States using data from the <a href='https://ridb.recreation.gov/' target='_blank'>Recreation Information Database (RIDB)</a>, which is part of the federal Recreation One Stop (R1S) program.</p>

      <p>The goal of this application is to provide users with an interactive way to:</p>
      <ul>
        <li>Search for recreation facilities by <strong>state</strong>, <strong>ZIP code</strong>, and <strong>activity</strong></li>
        <li>View and download detailed facility data</li>
        <li>Summarize the dataset using contingency tables and statistical summaries</li>
      </ul>

      <h4>Tabs Overview</h4>
      <ul>
        <li><strong>Search Facilities</strong>: Query the RIDB API for facilities based on ZIP code, state, and activity. Download and explore the resulting dataset.<br>Users can select from a list of activities populated by a call to the API</li>
        <li><strong>Explore</strong>: Create interactive plots and view a map of facilities. Details on a specific facility, including campsites (if any) and addresses can be fetched by clicking 'Fetch Details' on the facility map marker popup.<br>Note: There may be some issues with correct coordinates when searching by some states, causing facilities to be mapped outside of the state. This is a suspected issue with the RIDB source.</li>
      </ul>

      <img src='imgs/RecLogo_Tag.png' height='120px'>
      
      <p>Data Source: <a href='https://ridb.recreation.gov/' target='_blank'>RIDB (Recreation.gov API)</a></p>


      <p>Developed by Mike Keating</p>
    ")
              )
    ),
    
    nav_panel("Search Facilities",
              sidebarLayout(
                sidebarPanel(
                  h3("Search for Recreation Facilities"),
                  h5("Optionally Select Activities"),
                  selectInput("activity", "Select Activity", choices = NULL, selected = NULL, multiple = TRUE),
                  hr(),
                  h5("Search by State or Zip Code"),
                  # Allow drop down of all states using built in state.abb function
                  selectInput("state", "Enter State", choices = state.abb, multiple = FALSE),
                  actionButton("search_by_state", "Search Facilities by State"),
                  hr(),
                  textInput("zip", "Enter Zip Code", value = "37738"),
                  numericInput("radius_miles", "Search Radius (miles)", value = 25, min=1,max=50),
                  actionButton("search_by_zip", "Search Facilities by Zip"),
                  hr(),
                  uiOutput("column_selector"),
                  downloadButton("download_data", "Download CSV")
              ),
              mainPanel(dataTableOutput("facility_table")
                        )
              )
              ),
    nav_panel("Explore",
              fluidPage(
                selectInput("explore_mode", "Choose View",
                            choices = c("Plot" = "plot", "Map" = "map"),
                            selected = "map"),
                conditionalPanel(
                  condition = "input.explore_mode == 'plot'",
                  sidebarLayout(
                    sidebarPanel(
                      selectInput("plot_type", "Plot Type",
                                  choices = c("Activity Count by X", "Top Recreation Areas", "Heatmap: Facility Type vs Recreation Area")),
                      
                      # Add another conditional panel to hide choices when not relevant for the other plots
                      conditionalPanel(
                        condition = "input.plot_type == 'Activity Count by X'",
                        selectInput("x_var", "X Variable", 
                                    choices = c("OrgName","RecAreaName", "Reservable", "FacilityTypeDescription" )),
                        selectInput("group_var", "Group / Fill Variable", 
                                    choices = c("None", "OrgName", "RecAreaName", "FacilityTypeDescription", "Reservable")),
                        checkboxInput("add_facet", "Facet by Group?", value = FALSE)
                      )
                    ),
                    mainPanel(
                      plotOutput("explore_plot"),
                      hr(),
                      tableOutput("summary_table")
                    )
                  )
                ),
                
                conditionalPanel(
                  condition = "input.explore_mode == 'map'",
                  sidebarLayout(
                    sidebarPanel(
                      h5("Color Grouping"),
                      selectInput("map_color_group", "Color Map Markers By:",
                                  choices = c("Organization"="OrgName",
                                              "Recreation Area" = "RecAreaName",
                                              "Facility Type" = "FacilityTypeDescription"),
                                  selected = "RecAreaName"),
                      h5("Contingency Table"),
                      selectInput("contingency_choice", "Select Contingency Table",
                                  choices = c("Org x Facility Type" = "orgXtype",
                                              "Rec Area x Facility Type" = "areaXtype",
                                              "Org x Rec Area" = "orgXarea")),
                      tableOutput("contingency_table")),
                    mainPanel(
                      leafletOutput("facility_map", height = 600))
                  ),
                  
          
                 
                )
              )
    ),
    
    
    nav_panel("Facility Details",
              fluidPage(
                # Since this will only be populated after querying a facility we need to make it output
                uiOutput("selected_facility_title"),
                dataTableOutput("facility_addresses"),
                dataTableOutput("facility_campgrounds"),
              )),
    
    id = "tab"
  )
)

server <- function(input, output, session){
  
  facilities <- reactiveVal(NULL)
  activities <- reactiveVal(NULL)
  
  ### SEARCH TAB
  # Search for and download data
  # Populate the dropdown for activities on startup
  observe({
    act <- get_activities()
    activities(act)
    
    updateSelectInput(inputId = "activity",
                      choices = setNames(act$ActivityID, act$ActivityName))
  })
  
  observeEvent(input$search_by_zip, {
    req(input$zip)
    facs <- get_facilities(zip_code = input$zip, radius_miles = input$radius_miles)
    facilities(facs)
  })
  
  observeEvent(input$search_by_state,{
    req(input$state)
    # Add a progress bar
    withProgress(message = "Searching for facilities...", value = 0.1 ,{
      facs <- get_facilities(state=input$state, activity = input$activity)
      facilities(facs)
    })
 
  })
  
  # Display the returned data
  #https://stackoverflow.com/questions/71083229/with-dt-datatable-is-it-possible-to-have-a-column-that-holds-very-long-case-n
  output$facility_table <- renderDataTable({
    req(facilities())
    selected_cols <- input$columns %||% names(facilities())
    # Don't display the columns that contain objects
    # We want to keep them in the actual tibble though
    selected_cols <- setdiff(selected_cols, c("ACTIVITY", "ORGANIZATION", "CAMPSITE", "RECAREA"))
    
    # Show a note if our api call returns nothing
    if (nrow(facilities()) == 0) {
      return(datatable(
        tibble(Note = "No facilities found for the selected criteria."),
        # Hide all the pages etc since we are just showing a note
        options = list(dom = 't')  
      ))
    }
    
    datatable(
      facilities()[,selected_cols, drop = FALSE],
      filter = "top",
      options = list(
        scrollX = TRUE,
        columnDefs = list(
          list(
            # Apply the ellipsis truncation to every selected column
            targets = seq_along(selected_cols)-1,  
            # Here we are going to truncate long text to 50 characters
            render = JS("$.fn.dataTable.render.ellipsis(50, false)")  
          )
        )
      ),
      plugins = "ellipsis"
    )
  })
  
  # Select columns
  output$column_selector <- renderUI({
    req(facilities())
    checkboxGroupInput(
      "columns",
      "Select Columns to Keep",
      choices = setdiff(names(facilities()), c("ACTIVITY", "ORGANIZATION", "CAMPSITE", "RECAREA")),
      selected = setdiff(names(facilities()), c("ACTIVITY", "ORGANIZATION", "CAMPSITE", "RECAREA")),

    )
  })
  
  output$download_data <- downloadHandler(
    filename = function(){
      paste0("facilities_", Sys.Date(), ".csv")
    },
    content = function(file){
      req(facilities())
      
      # Find the rows filtered (in the top columns)
      filtered_rows <- input$facility_table_rows_all # Note: this input is automatically made from renderDataTable
      
      # Fall back to all rows if nothing is filtered
      df <- facilities()
      df <- df[filtered_rows %||% seq_len(nrow(df)), , drop = FALSE]
      
      selected_cols <- input$columns %||% names(facilities())
      # remove list columns to prevent download error
      selected_cols <- setdiff(selected_cols, c("ACTIVITY", "ORGANIZATION", "ATTRIBUTES", "CAMPSITE", "RECAREA")) 
      
      df <- df[, selected_cols, drop = FALSE]
      
      write.csv(df, file, row.names = FALSE)  
    },
    contentType = "text/csv"
  )
  
  
  
  # EXPLORE TAB

  # Change  var plot options by selected plot type
  observeEvent(input$plot_type,{
    req(facilities())
    df <- facilities()
    
    if (input$plot_type == "Activity Count by X"){
      x_choices <- c("OrgName", "RecAreaName")
      group_choices <- c("None", "OrgName", "RecAreaName", "FacilityTypeDescription", "Reservable")
      
    }
    else if (input$plot_type == "Heatmap: Facility Type vs Recreation Area"){
      x_choices <- c("None")
      group_choices <- c("None")
    }
    else if(input$plot_type == "Top Recreation Areas"){
      x_choices <- c("None")
      group_choices <- c("RecAreaName")
    }
    
    # Update to only allow a few options
    updateSelectInput(inputId = "x_var", choices = x_choices)
    updateSelectInput(inputId = "group_var", choices = group_choices)
    
  })
  
  output$explore_plot <- renderPlot({
    req(facilities(), input$x_var, input$plot_type)
    
    create_explore_plot(
      df = facilities(),
      x_var = input$x_var,
      group_var = input$group_var,
      plot_type = input$plot_type,
      facet = input$add_facet
    )
  })
  

  ## INTERACTIVE MAP
  output$facility_map <- renderLeaflet({
    req(facilities(), input$map_color_group)
  
    create_facilities_map(facilities(), input$map_color_group)
    
  })
  
  output$contingency_table <- renderTable({
    req(facilities(), input$contingency_choice)

    return(create_contingency_table(facilities(), input$contingency_choice))
  })
  
  ### FACILITY DETAILS TAB
  selected_facility_details<- reactiveVal(NULL)
  
  
  # Fetch details, we will render addresses and campsites separately later
  observeEvent(input$fetch_facility, {
    req(input$fetch_facility)
    # Change over to the details tab
    updateTabsetPanel(session, "tab", selected = "Facility Details")
    
    withProgress(message = "Fetching facility details...", value = 0.5, {
      details <- get_facility_details(input$fetch_facility)
      selected_facility_details(details)
    })
  })
  
  output$facility_campgrounds <- renderDataTable({
    req(selected_facility_details)
    
    campsites <- selected_facility_details()$campsites
    
    
    return(datatable(campsites, options = list(pagelength=4, scrollX = TRUE)))
    
  })
  
  output$facility_addresses <- renderDataTable({
    req(selected_facility_details)
    addresses <- selected_facility_details()$addresses
    
    return(datatable(addresses, options = list(pagelength = 4, scrollX = TRUE)))
  })
  
  output$selected_facility_title <- renderUI({
    req(facilities(), input$fetch_facility)
    facility_name <- facilities() |> filter(FacilityID == input$fetch_facility) |> pull(FacilityName)
    
    return(h3(paste0(facility_name, " | Details")))
  })
  
    
}

shinyApp(ui = ui, server = server)