library(shiny)
library(shinydashboard)
library(DT)
library(tidyverse)
library(tidyquant)
library(tbl2xts)
library(ggplot2)
library(knitr)
library(dygraphs)
library(timetk)
library(sweep)
library(forecast)

library(xml2)
library(rvest)

url <- "http://www.nasdaqomxnordic.com/shares/listed-companies/norwegian-listed-shares" #url for where the ticker data is colleted 

raw <- read_html(url)

OSEBX_indeksen <- html_table(raw)[[1]] %>%
  mutate(Symbol = substr(Symbol, 1, nchar(Symbol)-1)) #%>%
#mutate(Symbol = paste0(Symbol, ".OL", sep = ""))

#Create vector with all the tickers. Adding ".OL". Without .OL code will not work with Yahoo  
OSEBX_tickers <- paste0(OSEBX_indeksen[["Symbol"]], ".OL") 

#Add names to the charachers in the vector, 
names(OSEBX_tickers) =  paste0(OSEBX_indeksen[["Name"]]) 

#Repeat the process for the list of benchnames
Bench<-"^OSEAX" #^OSEAX is the name of the ALl-share Index at Yahoo 
names(Bench) = paste0("Oslo Børs All-Share Index") #Asign name to the characher ^OSEAX
benchnames <-c(Bench,OSEBX_tickers) #New vector of OSEBX tickers plus ^OSEAX

# Risk-free rate
TB1YR <- 
  tq_get("TB1YR",get = "economic.data") %>%
  arrange(desc(date))

rf <- as.numeric(TB1YR[1,3])

# PROBLEM: rf blir automatisk annualisert??

stocks<- benchnames %>% 
  tq_get( #use tidyquant to get stockprices
    get = "stock.prices", #get prices from Yahoo
    from = as.character(Sys.Date()-years(1)), #refer to the input dates in the UI
    to = as.character(Sys.Date()))%>%
  rename("symbol"="Oslo Børs All-share Index")%>%
  tbl_xts(
    cols_to_xts =adjusted,
    spread_by = symbol)%>%
  Return.calculate()%>%
  table.AnnualizedReturns(Rf = rf*0.01/365, scale = 252)%>%
  rownames_to_column()%>%
  rename('Measure'='rowname')%>% 
  gather(key = 'Stock', value = 'Values', -Measure) %>% 
  spread(key = Measure, value = Values) %>%
  #colnames() <- c("Return", "Sharpe", "Std Dev")
  rename('Return' = 'Annualized Return', 
         'Sharpe' = paste("Annualized Sharpe (Rf=",round(rf/365*252, digits = 2),"%)", sep=""),
         'StdDev' = 'Annualized Std Dev' )




#------------------

ui<-dashboardPage(
  dashboardHeader(title = "Stock app"),
  dashboardSidebar(
    sidebarMenu(
      menuItem("Stock explorer", tabName = "stock", icon=icon("search")),
      menuItem("Overview OSEBX", tabName = "osebx", icon=icon("globe")),
      menuItem("Risk & Forecast", tabName = "risk", icon = icon("book"))
      
    )
  ),
  dashboardBody(
    tabItems(
      tabItem("stock",
              box(
                sidebarPanel( 
                  selectizeInput("stock_id", "Stock:", c("Choose stock to examine" = "", OSEBX_tickers)), 
                  dateRangeInput("dates", 
                                 "Date range", 
                                 start = "2019-01-01",
                                 end = as.character(Sys.Date()),
                                 max = as.character(Sys.Date()),
                                 format = "dd/mm/yyyy",
                                 startview = "year"),
                  selectizeInput("bench_id", "Compare to:", c("Choose index/stock for comparison" = "", benchnames)),
                  textOutput("valid"),
                  textOutput("omitted"),
                  width = "100%" 
                ), 
                
              ),
              box(plotOutput("stock"), width = 6),
              box(plotOutput("returns"), width = 6),
              box(plotOutput("comp"), width = 6)
      ),
      tabItem("osebx",
              plotOutput("check",width = "100%"),
              dataTableOutput(outputId = "stocksTable", width = "100%")
      ),
      tabItem("risk",
              plotOutput(outputId = "models_tbl",width = "100%"),
              plotOutput("VaR", width = "100%")
      )
    )
  )
)




server<-function(input,output){
  dataInput <- reactive({  #reactive means sensitive to user input 
    
    # Require input from user
    validate(
      need(input$stock_id, 
           "Please select a stock from the drop-down"))
    validate(
      need(input$dates[1] < input$dates[2], 
           "Start date (left) must be prior to end date (right)"))
    
    
    stocks_return<- input$stock_id %>% 
      tq_get( #use tidyquant to get stockprices
        get = "stock.prices", #get prices from Yahoo
        from = input$dates[1], #refer to the input dates in the UI
        to = input$dates[2]) %>%
      group_by(symbol) %>% #group by ticker name (stock,benchmark)
      tq_transmute( #select adjusted return column to calculate daily returns 
        select = adjusted,
        mutate_fun = periodReturn, #Add periode returns to the dataframe. Column will be used in plots 
        period = "daily",
        col_rename = "returns")
    
    plot_var <- input$stock_id%>%
      tq_get( #use tidyquant to get stockprices
        get = "stock.prices", #get prices from Yahoo
        from = input$dates[1], #refer to the input dates in the UI
        to = input$dates[2])%>%
      tbl_xts(
        cols_to_xts =adjusted)%>%
      Return.calculate()
    
    
    stock <- input$stock_id %>% #create dataframe with input stock data. Use the input form UI
      tq_get(get = "stock.prices", 
             from = input$dates[1],
             to = input$dates[2])
    
    #dataframe with both stock data and bench data
    bench <-c(input$stock_id, input$bench_id)%>% #use the input from the UI to select which to use 
      tq_get(get = "stock.prices",
             from = input$dates[1],
             to = input$dates[2])
    
    bench_stock <- bench%>% #Use the bench dataframe and normalize the data in order to compare the stock to benchmark
      group_by(symbol)%>% #group by symbol 
      summarize(
        first_day = head(close, n = 1)) %>%
      full_join(bench) %>%
      mutate(close = 100*close/first_day) 
    
    
    stock.prediction <- input$stock_id %>% 
      tq_get( #use tidyquant to get stockprices
        get = "stock.prices", #get prices from Yahoo
        from = as.character(Sys.Date()-years(4)), #refer to the input dates in the UI
        to = as.character(Sys.Date()))%>%
      tq_transmute(
        select = adjusted,
        mutate_fun = to.period,
        period = "months") %>% 
      tk_ts(select = -date, freq = 12)
    
    
    models_list <- list(
      auto.arima = list(
        y = stock.prediction
      ),
      ets = list(
        y = stock.prediction,
        damped = TRUE
      )
    )
    
    
    models_tbl <- enframe(models_list, name = "f", value = "params")%>%
      mutate(fit = invoke_map(f, params))%>%
      mutate(fcast = map(fit, forecast, h = 6))%>%
      mutate(sweep = map(fcast, sw_sweep, fitted = FALSE, timetk_idx = TRUE, rename_index = "date"))
    
    validation <- bench %>%
      filter(is.na(close))
    
    
    #In order to refer to the right dataframe when drawing the plots 
    #thus, the different dataframes used are listed. 
    list(stocks_return, stock, bench_stock, stocks,plot_var, models_tbl, validation)
  })
  
  #-----
  
  output$returns <- renderPlot({ #Generate the plot
    dataInput<-dataInput()[[1]] # Refer to list the list for stock returns first 
    dataInput%>%
      ggplot(aes(x = date, y = returns))+ #use returns column 
      geom_bar(stat = "identity", fill = palette_light()[[1]]) + 
      labs(title = "Daily Returns",
           x = "", y = "") + 
      geom_smooth(method = "lm") + #include the regression line to show development
      theme_classic() + 
      scale_color_tq() + 
      scale_y_continuous(labels = scales::percent) #Set scale to percent 
  }) 
  output$stock <-renderPlot({
    dataInput<-dataInput()[[2]] #Refer to the second index in the list
    dataInput%>%
      ggplot(aes(x = date, y = adjusted))+ #use adjusted returns column
      geom_line(aes(color = input$stock_id), size = 0.5, show.legend = T) +
      labs(title = "Stock Performance",
           x = "", y = "") +
      # Adding Simple Moving Averages (20-day and 50-day)
      geom_ma(aes(color = 'SMA(20)'), ma_fun = SMA, n = 20, size = 0.5, show.legend = T) +
      geom_ma(aes(color = 'SMA(50)'), ma_fun = SMA, n = 50, size = 0.5, show.legend = T) +
      theme_classic() +
      theme(legend.title=element_blank()) +
      scale_color_tq()
  })
  
  output$comp<-renderPlot({ 
    dataInput<-dataInput()[[3]] #Refer to the third index in the list 
    dataInput%>%
      ggplot(aes(x = date, y = close, group = symbol))+ #group by symbol, meaning stock and benchmark 
      geom_line(aes(color=symbol )) + #diffrent colours to the different lines 
      scale_color_manual(values=c('blue','grey0')) + #Set specific colours for the different lines 
      labs(title = "Comparison",
           x = "", y = "") +
      theme_classic() +
      theme(legend.title=element_blank()) +
      scale_x_date(expand = c(.14, 0))
  })
  output$check<-renderPlot({
    dataInput<-dataInput()[[4]]
    dataInput%>%
      ggplot(aes(y = Return, x = StdDev)) +
      geom_rect(aes(xmin = -Inf, xmax= Inf), ymin = rf, ymax= Inf, fill = 'green', alpha = 0.01) + 
      geom_rect(aes(xmin = -Inf, xmax= Inf), ymin = -Inf, ymax= rf, fill = 'red', alpha = 0.01) +
      geom_hline(aes(yintercept = rf, color = 'white')) + 
      geom_label(label = dataInput$Stock, size = 2) + 
      annotate(geom ='text',
               x=0.8, 
               y=rf, 
               label ='Risk-Free Rate (One-year T-bill)', 
               size = 4.5) + 
      theme_bw() + 
      xlab('Standard Deviation') + 
      ylab('Actual Returns') + 
      ggtitle('Overall Stock Performance vs Risk-Free Rate') +
      theme(axis.text = element_text(size = 14), 
            plot.title = element_text(size =20, hjust = 0.5),
            axis.title = element_text(size = 16))
  })
  output$stocksTable <- DT::renderDataTable({
    stocks.df <- dataInput()[[4]]
    stocks.df#[, c("ticker", "beta", "alpha", "r2")]
  }, server = TRUE, selection = "single")
  
  output$VaR <-renderPlot({
    dataInput<-dataInput()[[5]]
    chart.VaRSensitivity(dataInput[,1,drop=FALSE],
                         methods=c("HistoricalVaR", "ModifiedVaR", "GaussianVaR"), 
                         colorset=bluefocus, lwd=2)
  })
  output$models_tbl<-renderPlot({
    dataInput<-dataInput()[[6]]
    dataInput %>%
      unnest(sweep) %>%
      ggplot(aes(x = date, y = adjusted, color = key, group = f)) +
      geom_ribbon(aes(ymin = lo.95, ymax = hi.95), 
                  fill = "#D5DBFF", color = NA, size = 0) +
      geom_ribbon(aes(ymin = lo.80, ymax = hi.80, fill = key), 
                  fill = "#596DD5", color = NA, size = 0, alpha = 0.8) +
      geom_line(size = 1) +
      facet_wrap(~f, nrow = 3) +
      labs(title = "Stock forecast using different models",
           subtitle = "Forecasting multiple models with sweep: ARIMA, ETS",
           x = "", y = "Price") +
      scale_y_continuous(labels = scales::number) +
      scale_x_date(date_breaks = "5 years", date_labels = "%Y") +
      theme_tq() +
      scale_color_tq()
    
  })
  # Validate
  output$valid <- renderText({
    
    if (nrow(dataInput()[[1]]) > 1) {
      paste("Data was successfully retrieved from yahoo! finance at", " ", as.character(Sys.time()))
    }
    else {
      paste("Application failed to retrieve data from yahoo! finance.
            Try selecting a different time period.")
    }
  })
  
  # Omitted values
  output$omitted <- renderText({
    
    if (nrow(dataInput()[[7]]) > 0) {
      paste("Note:", "", 
            nrow(dataInput()[[7]]), "", 
            "missing observation(s) omitted for the selected time period.")
    }
    
  })
  
  
}


shinyApp(ui,server)
